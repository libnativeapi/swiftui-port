#if os(Linux)
import CGTK3
import Foundation
import NativeAPI
import SwiftUIRuntime

/// Paints the shared desktop layout in a GTK window and retains its native text editors.
public final class LinuxDrawingBackend: RenderBackend {
  public var tapHandler: ((NodeID) -> Void)?
  public var transactionHandler: ((() -> Void) -> Void)?
  public var inputHandler: ((NodeID?, Int, CGPoint, Int, EventModifiers, String) -> Bool)?
  public var interactionHandler: ((NodeID, Renderer.Interaction) -> Void)?
  public var onResize: ((SwiftUIRuntime.Size) -> Void)?

  private let window: NativeAPI.Window
  private let content: NativeAPI.View
  private let canvas: Widget
  private let host: Widget
  private let surface: Widget
  private let drawing = LinuxDrawing()
  private var root: Element?
  private var listener: ListenerId?
  private var queuedRender: (() -> Void)?
  private var updateSource: UInt32 = 0
  private var pointerSource: UInt32 = 0
  private var pendingPointer: (event: Int, point: CGPoint, modifiers: EventModifiers)?
  private var controls: [NodeID: Editor] = [:]
  private var buttons: [NodeID: Activation] = [:]
  private var controlBranches: Set<NodeID> = []
  private var modal: NodeID?
  private var signals: [gulong] = []
  private var allocationSignal: gulong = 0
  private var windowScrollSignal: gulong = 0
  private var applying = false
  private var tick: UInt32 = 0
  private var motions: [NodeID: LinuxDrawing.Motion] = [:]
  private var motionDamage: [NodeID: Rect] = [:]
  private var prior: [NodeID: LinuxDrawing.DrawingValues] = [:]
  private let trace = ProcessInfo.processInfo.environment["SWIFTUI_PORT_LINUX_TRACE"] == "1"

  fileprivate typealias Widget = UnsafeMutablePointer<GtkWidget>
  private static let connectAfter = GConnectFlags(rawValue: 1)

  public init?(window: NativeAPI.Window) {
    guard let content = window.contentView, let native = content.nativeObject,
          let canvas = gtk_drawing_area_new(), let host = gtk_fixed_new(),
          let surface = gtk_overlay_new() else { return nil }
    self.window = window
    self.content = content
    self.canvas = canvas
    self.host = host
    self.surface = surface
    g_object_ref_sink(surface)
    g_object_ref_sink(host)
    g_object_ref_sink(canvas)
    let container = native.assumingMemoryBound(to: GtkFixed.self)
    gtk_container_add(typed(surface, GtkContainer.self), canvas)
    gtk_overlay_add_overlay(typed(surface, GtkOverlay.self), host)
    gtk_widget_set_halign(host, GTK_ALIGN_FILL)
    gtk_widget_set_valign(host, GTK_ALIGN_FILL)
    gtk_overlay_set_overlay_pass_through(typed(surface, GtkOverlay.self), host, 1)
    gtk_fixed_put(container, surface, 0, 0)
    gtk_widget_show(host)
    gtk_widget_set_can_focus(canvas, 1)
    gtk_widget_add_events(canvas, Int32(
      GDK_POINTER_MOTION_MASK.rawValue | GDK_BUTTON_PRESS_MASK.rawValue | GDK_BUTTON_RELEASE_MASK.rawValue
        | GDK_SCROLL_MASK.rawValue | GDK_SMOOTH_SCROLL_MASK.rawValue | GDK_LEAVE_NOTIFY_MASK.rawValue
        | GDK_KEY_PRESS_MASK.rawValue))
    let context = Unmanaged.passUnretained(self).toOpaque()
    let allocate: @convention(c) (Widget?, UnsafeMutablePointer<GtkAllocation>?, UnsafeMutableRawPointer?) -> Void = { _, size, data in
      guard let size, let data else { return }
      let backend = Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue()
      var allocation = size.pointee
      gtk_widget_size_allocate(backend.surface, &allocation)
    }
    allocationSignal = g_signal_connect_data(container, "size-allocate", unsafeBitCast(allocate, to: GCallback.self),
                                             context, nil, Self.connectAfter)
    let draw: @convention(c) (Widget?, OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean = { _, cairo, data in
      guard let cairo, let data else { return 0 }
      let backend = Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue()
      if let tree = backend.root {
        let start = backend.trace ? g_get_monotonic_time() : 0
        var x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0
        cairo_clip_extents(cairo, &x1, &y1, &x2, &y2)
        let damage = Rect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        backend.drawing.paint(tree, in: cairo, clip: tree.frame, damage: damage, motions: backend.motions,
                              now: Date.timeIntervalSinceReferenceDate)
        if backend.trace { backend.log("GTK paint \(Double(g_get_monotonic_time() - start) / 1000)") }
      }
      return 0
    }
    signals.append(g_signal_connect_data(canvas, "draw", unsafeBitCast(draw, to: GCallback.self), context, nil, .init(rawValue: 0)))
    let callback: @convention(c) (Widget?, UnsafeMutablePointer<GdkEvent>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      return Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue().pointer(event)
    }
    for name in ["motion-notify-event", "button-press-event", "button-release-event", "scroll-event", "leave-notify-event"] {
      signals.append(g_signal_connect_data(canvas, name, unsafeBitCast(callback, to: GCallback.self), context, nil, .init(rawValue: 0)))
    }
    // The native overlay may be the scroll target between two controls.
    // Unhandled wheel events bubble to the toplevel in that case.
    if let top = window.nativeObject {
      let widget = top.assumingMemoryBound(to: GtkWidget.self)
      gtk_widget_add_events(widget, Int32(GDK_SCROLL_MASK.rawValue | GDK_SMOOTH_SCROLL_MASK.rawValue))
      windowScrollSignal = g_signal_connect_data(top, "scroll-event", unsafeBitCast(callback, to: GCallback.self),
                                                 context, nil, .init(rawValue: 0))
    }
    let key: @convention(c) (Widget?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      return Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue().key(event.pointee, id: nil)
    }
    signals.append(g_signal_connect_data(canvas, "key-press-event", unsafeBitCast(key, to: GCallback.self), context, nil, .init(rawValue: 0)))
    gtk_widget_show(canvas)
    gtk_widget_show(surface)
    listener = window.addListener { [weak self] event in
      guard let self, case .resized = event else { return }
      let size = self.window.contentSize
      self.onResize?(SwiftUIRuntime.Size(width: size.width, height: size.height))
    }
  }

  deinit {
    if updateSource != 0 { g_source_remove(updateSource) }
    if pointerSource != 0 { g_source_remove(pointerSource) }
    if tick != 0 { gtk_widget_remove_tick_callback(canvas, tick) }
    if let listener { _ = window.removeListener(listener) }
    if let native = content.nativeObject, allocationSignal != 0,
       g_signal_handler_is_connected(native, allocationSignal) != 0 {
      g_signal_handler_disconnect(native, allocationSignal)
    }
    if let top = window.nativeObject, windowScrollSignal != 0,
       g_signal_handler_is_connected(top, windowScrollSignal) != 0 {
      g_signal_handler_disconnect(top, windowScrollSignal)
    }
    controls.removeAll()
    buttons.removeAll()
    for signal in signals where g_signal_handler_is_connected(canvas, signal) != 0 {
      g_signal_handler_disconnect(canvas, signal)
    }
    gtk_widget_destroy(surface)
    g_object_unref(canvas)
    g_object_unref(host)
    g_object_unref(surface)
  }

  public func measureText(_ text: String, font: Font) -> SwiftUIRuntime.Size {
    drawing.measure(text, font: font)
  }

  public func requestRender(_ render: @escaping () -> Void) -> Bool {
    queuedRender = render
    if updateSource == 0 {
      updateSource = g_idle_add({ data in
        guard let data else { return 0 }
        let backend = Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue()
        backend.updateSource = 0
        let update = backend.queuedRender
        backend.queuedRender = nil
        update?()
        return 0
      }, Unmanaged.passUnretained(self).toOpaque())
    }
    return updateSource != 0
  }

  public func perform(_ commands: [RenderCommand]) {}
  public var needsRenderCommands: Bool { false }

  public func didRender(_ root: Element) {
    updateMotions(root)
    controlBranches.removeAll(keepingCapacity: true)
    modal = nil
    indexControls(root)
    publish(root)
  }

  public func didScroll(_ root: Element) { publish(root) }

  public func didMeasureRender(_ timings: [String: Double]) {
    if trace {
      let stages = ["evaluate", "environment", "layout", "layout.identify", "layout.place",
                    "layout.geometry", "layout.prune", "finalize", "diff", "scroll.translate", "backend"]
      log("GTK render " + stages.compactMap { name in
        timings[name].map { "\(name)=\($0)" }
      }.joined(separator: " "))
    }
  }

  private func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private func publish(_ root: Element) {
    self.root = root
    updateVisibleMotions(in: root)
    applying = true
    defer { applying = false }
    var live = Set<NodeID>()
    var liveButtons = Set<NodeID>()
    var focus: NodeID?
    updateControls(root, clip: root.frame, background: .white, allowed: true, focus: &focus, modal: modal,
                   inModal: false, accessibilityLabel: "", live: &live, liveButtons: &liveButtons)
    for id in controls.keys.filter({ !live.contains($0) }) { controls.removeValue(forKey: id) }
    for id in buttons.keys.filter({ !liveButtons.contains($0) }) { buttons.removeValue(forKey: id) }
    if let focus {
      if let edit = controls[focus] {
        if gtk_widget_has_focus(edit.input) == 0 { gtk_widget_grab_focus(edit.input) }
      } else if let button = buttons[focus], gtk_widget_has_focus(button.widget) == 0 {
        gtk_widget_grab_focus(button.widget)
      }
    }
    gtk_widget_queue_draw(canvas)
  }

  private func updateMotions(_ root: Element) {
    let now = Date.timeIntervalSinceReferenceDate
    var next: [NodeID: LinuxDrawing.DrawingValues] = [:]
    next.reserveCapacity(prior.count)
    func visit(_ node: Element, animation: Animation?) {
      let animation = node.props.animation ?? animation
      let values = LinuxDrawing.DrawingValues(node.props)
      if let animation, animation.duration > 0, let old = prior[node.id], old != values {
        motions[node.id] = LinuxDrawing.Motion(from: old, animation: animation, start: now + animation.delay)
      }
      next[node.id] = values
      for child in node.children { visit(child, animation: animation) }
    }
    visit(root, animation: nil)
    prior = next
    motions = motions.filter { next[$0.key] != nil }
  }

  private func updateVisibleMotions(in root: Element) {
    motionDamage.removeAll(keepingCapacity: true)
    if !motions.isEmpty {
      func collect(_ node: Element, clip: Rect) {
        guard node.props.visible, !clip.isEmpty else { return }
        if let motion = motions[node.id] {
          let frame = node.frame
          let dx = motion.from.offsetX - node.props.offsetX
          let dy = motion.from.offsetY - node.props.offsetY
          let scale = max(1, abs(motion.from.scaleX), abs(motion.from.scaleY),
                          abs(node.props.scaleX), abs(node.props.scaleY))
          let rotates = motion.from.rotation != node.props.rotation || node.props.rotation != 0
          let spread = rotates ? (hypot(frame.width, frame.height) * scale) / 2 : 0
          let shadow = node.props.shadows.map { $0.radius + max(abs($0.x), abs($0.y)) }.max() ?? 0
          let padX = max(spread, frame.width * (scale - 1) / 2) + shadow + 2
          let padY = max(spread, frame.height * (scale - 1) / 2) + shadow + 2
          let bounds = Rect(
            x: frame.minX + min(0, dx) - padX, y: frame.minY + min(0, dy) - padY,
            width: frame.width + abs(dx) + padX * 2, height: frame.height + abs(dy) + padY * 2
          ).intersection(clip)
          if !bounds.isEmpty { motionDamage[node.id] = bounds }
        }
        let childClip = node.props.clipped ? clip.intersection(node.frame) : clip
        for child in node.children { collect(child, clip: childClip) }
      }
      collect(root, clip: root.frame)
    }
    if trace { log("GTK visible animations \(motionDamage.count)/\(motions.count)") }
    if !motionDamage.isEmpty && tick == 0 {
      tick = gtk_widget_add_tick_callback(canvas, { _, _, data in
        guard let data else { return 0 }
        let backend = Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue()
        let now = Date.timeIntervalSinceReferenceDate
        for rect in backend.motionDamage.values {
          gtk_widget_queue_draw_area(backend.canvas, pixels(floor(rect.minX)), pixels(floor(rect.minY)),
                                     pixels(ceil(rect.width) + 1), pixels(ceil(rect.height) + 1))
        }
        backend.motions = backend.motions.filter {
          $0.value.animation.repeats || now < $0.value.start + $0.value.animation.duration
        }
        backend.motionDamage = backend.motionDamage.filter { backend.motions[$0.key] != nil }
        if backend.motionDamage.isEmpty { backend.tick = 0; return 0 }
        return 1
      }, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
  }

  public func focusInitialControl() { gtk_widget_grab_focus(canvas) }

  fileprivate func sendText(_ text: String, from id: NodeID) {
    if !applying { _ = inputHandler?(id, 7, .zero, 0, [], text) }
  }

  fileprivate func activate(_ id: NodeID) {
    if !applying { tapHandler?(id) }
  }

  fileprivate func focus(_ id: NodeID, gained: Bool) {
    if !applying { interactionHandler?(id, .focus(gained)) }
  }

  @discardableResult private func indexControls(_ node: Element) -> Bool {
    let isModal = node.props.accessibilityTraits & AccessibilityTraits.isModal.rawValue != 0
    if isModal && modal == nil { modal = node.id }
    var hasControls = node.kind == .textField || node.kind == .button || node.kind == .styledButton
      || node.props.focusable
    for child in node.children.reversed() {
      if indexControls(child) { hasControls = true }
    }
    if hasControls { controlBranches.insert(node.id) }
    return hasControls
  }

  private func updateControls(_ node: Element, clip: Rect, background: SwiftUIRuntime.Color,
                              allowed: Bool, focus: inout NodeID?, modal: NodeID?, inModal: Bool,
                              accessibilityLabel: String,
                              live: inout Set<NodeID>, liveButtons: inout Set<NodeID>) {
    guard controlBranches.contains(node.id) else { return }
    let props = node.props
    let inModal = inModal || node.id == modal
    let allowed = allowed && props.visible && props.hitTesting
    let clip = props.clipped ? clip.intersection(node.frame) : clip
    let visible = node.frame.intersection(clip)
    let background = props.background.flatMap { $0.opacity > 0.99 ? $0 : nil } ?? background
    let accessibilityLabel = props.accessibilityLabel.isEmpty ? accessibilityLabel : props.accessibilityLabel
    let active = allowed && (modal == nil || inModal) && !visible.isEmpty
    if node.kind == .textField, active || controls[node.id] != nil {
      live.insert(node.id)
      if controls[node.id] == nil {
        controls[node.id] = Editor(node.id, props: props, host: typed(host, GtkFixed.self), backend: self)
      }
      if let editor = controls[node.id] {
        editor.update(props, visible: active ? visible : .zero, background: background, label: accessibilityLabel)
        if props.focusRequested && active { focus = node.id }
      }
    }
    if node.kind != .textField, (node.kind == .button || node.kind == .styledButton || props.focusable),
       active || buttons[node.id] != nil {
      liveButtons.insert(node.id)
      if buttons[node.id] == nil {
        buttons[node.id] = Activation(node.id, host: typed(host, GtkFixed.self), backend: self)
      }
      if let control = buttons[node.id] {
        control.update(node, visible: active ? visible : .zero, enabled: props.enabled && active)
        if props.focusRequested && active { focus = node.id }
      }
    }
    for child in LinuxDrawing.orderedChildren(node) {
      updateControls(child, clip: clip, background: background, allowed: allowed,
                     focus: &focus, modal: modal, inModal: inModal,
                     accessibilityLabel: accessibilityLabel, live: &live, liveButtons: &liveButtons)
      if props.focusRequested && active && focus == nil {
        focus = firstFocusable(child)
      }
    }
  }

  private func firstFocusable(_ node: Element) -> NodeID? {
    if node.props.enabled && (controls[node.id] != nil || buttons[node.id] != nil) { return node.id }
    return node.children.lazy.compactMap { self.firstFocusable($0) }.first
  }

  private func flushPointer() {
    if pointerSource != 0 {
      g_source_remove(pointerSource)
      pointerSource = 0
    }
    guard let pendingPointer else { return }
    self.pendingPointer = nil
    _ = inputHandler?(nil, pendingPointer.event, pendingPointer.point, 0, pendingPointer.modifiers, "")
  }

  private func queuePointer(_ event: Int, point: CGPoint, modifiers: EventModifiers) {
    pendingPointer = (event, point, modifiers)
    guard pointerSource == 0 else { return }
    pointerSource = g_idle_add({ data in
      guard let data else { return 0 }
      let backend = Unmanaged<LinuxDrawingBackend>.fromOpaque(data).takeUnretainedValue()
      backend.pointerSource = 0
      backend.flushPointer()
      return 0
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  fileprivate func pointer(_ event: UnsafeMutablePointer<GdkEvent>, origin: SwiftUIRuntime.Point = .zero,
                           button control: Widget? = nil, id: NodeID? = nil) -> gboolean {
    var x = 0.0, y = 0.0
    _ = gdk_event_get_coords(event, &x, &y)
    var state = GdkModifierType(rawValue: 0)
    _ = gdk_event_get_state(event, &state)
    var value = 0
    let type: Int
    switch event.pointee.type {
    case GDK_MOTION_NOTIFY: type = 1
    case GDK_BUTTON_PRESS:
      var button: UInt32 = 0
      _ = gdk_event_get_button(event, &button)
      if button == 3 { type = 9 }
      else if button == 1 { type = 2; gtk_widget_grab_focus(control ?? canvas) }
      else { return 0 }
    case GDK_BUTTON_RELEASE:
      var button: UInt32 = 0
      _ = gdk_event_get_button(event, &button)
      guard button == 1 else { return 0 }
      type = 3
    case GDK_2BUTTON_PRESS: type = 4
    case GDK_SCROLL:
      type = 5
      var dx = 0.0, dy = 0.0
      if gdk_event_get_scroll_deltas(event, &dx, &dy) != 0 {
        value = Int((abs(dy) >= abs(dx) ? -dy : -dx) * 90)
        if abs(dx) > abs(dy) { state = GdkModifierType(rawValue: state.rawValue | GDK_SHIFT_MASK.rawValue) }
      } else {
        var direction = GDK_SCROLL_DOWN
        _ = gdk_event_get_scroll_direction(event, &direction)
        value = direction == GDK_SCROLL_UP || direction == GDK_SCROLL_LEFT ? 120 : -120
        if direction == GDK_SCROLL_LEFT || direction == GDK_SCROLL_RIGHT {
          state = GdkModifierType(rawValue: state.rawValue | GDK_SHIFT_MASK.rawValue)
        }
      }
    case GDK_LEAVE_NOTIFY: type = 10
    default: return 0
    }
    if let eventWindow = gdk_event_get_window(event), let canvasWindow = gtk_widget_get_window(canvas) {
      if eventWindow != canvasWindow {
        var eventX: Int32 = 0, eventY: Int32 = 0
        var canvasX: Int32 = 0, canvasY: Int32 = 0
        _ = gdk_window_get_origin(eventWindow, &eventX, &eventY)
        _ = gdk_window_get_origin(canvasWindow, &canvasX, &canvasY)
        x += Double(eventX - canvasX)
        y += Double(eventY - canvasY)
      }
    } else {
      x += origin.x
      y += origin.y
    }
    let point = CGPoint(x: x, y: y)
    let flags = modifiers(state.rawValue)
    if type == 1 || type == 10 {
      queuePointer(type, point: point, modifiers: flags)
      return 1
    }
    flushPointer()
    let buttonID = type == 2 || type == 3 || type == 4 ? id : nil
    let handled = inputHandler?(buttonID, type, point, value, flags, "") == true
    if trace { log("GTK input event=\(type) x=\(point.x) y=\(point.y) handled=\(handled)") }
    if control != nil && (type == 2 || type == 3 || type == 4) { return 1 }
    return handled ? 1 : 0
  }

  fileprivate func key(_ event: GdkEventKey, id: NodeID?) -> gboolean {
    let special: [UInt32: Int] = [
      UInt32(GDK_KEY_BackSpace): 8, UInt32(GDK_KEY_Tab): 9, UInt32(GDK_KEY_ISO_Left_Tab): 9,
      UInt32(GDK_KEY_Return): 13, UInt32(GDK_KEY_KP_Enter): 13, UInt32(GDK_KEY_Escape): 27,
      UInt32(GDK_KEY_space): 32, UInt32(GDK_KEY_Page_Up): 33, UInt32(GDK_KEY_Page_Down): 34,
      UInt32(GDK_KEY_End): 35, UInt32(GDK_KEY_Home): 36, UInt32(GDK_KEY_Left): 37,
      UInt32(GDK_KEY_Up): 38, UInt32(GDK_KEY_Right): 39, UInt32(GDK_KEY_Down): 40,
      UInt32(GDK_KEY_Delete): 46,
    ]
    let value = special[event.keyval] ?? Int(gdk_keyval_to_unicode(event.keyval))
    guard value != 0 else { return 0 }
    return inputHandler?(id, 6, .zero, value, modifiers(event.state), "") == true ? 1 : 0
  }

  private func modifiers(_ state: UInt32) -> EventModifiers {
    var result: EventModifiers = []
    if state & GDK_SHIFT_MASK.rawValue != 0 { result.insert(.shift) }
    if state & GDK_CONTROL_MASK.rawValue != 0 { result.insert(.control) }
    if state & GDK_MOD1_MASK.rawValue != 0 { result.insert(.option) }
    if state & GDK_SUPER_MASK.rawValue != 0 { result.insert(.command) }
    return result
  }
}

private typealias Widget = UnsafeMutablePointer<GtkWidget>

private func pixels(_ value: Double) -> Int32 {
  guard value.isFinite else { return 0 }
  return Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
}

private func typed<T>(_ widget: Widget, _: T.Type) -> UnsafeMutablePointer<T> {
  UnsafeMutableRawPointer(widget).assumingMemoryBound(to: T.self)
}

private final class Activation {
  private static let style: OpaquePointer = {
    let provider = gtk_css_provider_new()!
    gtk_css_provider_load_from_data(provider,
      "button { min-width: 0; min-height: 0; padding: 0; border-width: 0; }", -1, nil)
    return OpaquePointer(provider)
  }()
  let widget: Widget
  private let host: UnsafeMutablePointer<GtkFixed>
  private let id: NodeID
  private weak var backend: LinuxDrawingBackend?
  private var signals: [gulong] = []
  private var name: String?
  private var help: String?
  private var placement = Rect.zero

  init(_ id: NodeID, host: UnsafeMutablePointer<GtkFixed>, backend: LinuxDrawingBackend) {
    self.id = id
    self.host = host
    self.backend = backend
    widget = gtk_button_new()!
    g_object_ref_sink(widget)
    gtk_style_context_add_provider(gtk_widget_get_style_context(widget), Self.style, 700)
    gtk_widget_set_opacity(widget, 0)
    gtk_fixed_put(host, widget, 0, 0)
    let data = Unmanaged.passUnretained(self).toOpaque()
    let activate: @convention(c) (Widget?, UnsafeMutableRawPointer?) -> Void = { _, data in
      guard let data else { return }
      let control = Unmanaged<Activation>.fromOpaque(data).takeUnretainedValue()
      control.backend?.activate(control.id)
    }
    signals.append(g_signal_connect_data(widget, "clicked", unsafeBitCast(activate, to: GCallback.self), data, nil, .init(rawValue: 0)))
    let key: @convention(c) (Widget?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      let control = Unmanaged<Activation>.fromOpaque(data).takeUnretainedValue()
      return control.backend?.key(event.pointee, id: control.id) ?? 0
    }
    signals.append(g_signal_connect_data(widget, "key-press-event", unsafeBitCast(key, to: GCallback.self), data, nil, .init(rawValue: 0)))
    let focus: @convention(c) (Widget?, UnsafeMutablePointer<GdkEventFocus>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      let control = Unmanaged<Activation>.fromOpaque(data).takeUnretainedValue()
      control.backend?.focus(control.id, gained: event.pointee.in != 0)
      return 0
    }
    for signal in ["focus-in-event", "focus-out-event"] {
      signals.append(g_signal_connect_data(widget, signal, unsafeBitCast(focus, to: GCallback.self), data, nil, .init(rawValue: 0)))
    }
    for signal in ["motion-notify-event", "button-press-event", "button-release-event", "scroll-event", "leave-notify-event"] {
      let pointer: @convention(c) (Widget?, UnsafeMutablePointer<GdkEvent>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
        guard let event, let data else { return 0 }
        let control = Unmanaged<Activation>.fromOpaque(data).takeUnretainedValue()
        let id = control.contains(event) ? control.id : nil
        return control.backend?.pointer(event, origin: control.placement.origin,
                                       button: control.widget, id: id) ?? 0
      }
      signals.append(g_signal_connect_data(widget, signal, unsafeBitCast(pointer, to: GCallback.self), data, nil, .init(rawValue: 0)))
    }
    gtk_widget_add_events(widget, Int32(GDK_POINTER_MOTION_MASK.rawValue | GDK_SCROLL_MASK.rawValue
      | GDK_SMOOTH_SCROLL_MASK.rawValue | GDK_LEAVE_NOTIFY_MASK.rawValue))
  }

  deinit {
    for signal in signals where g_signal_handler_is_connected(widget, signal) != 0 {
      g_signal_handler_disconnect(widget, signal)
    }
    gtk_widget_destroy(widget)
    g_object_unref(widget)
  }

  func contains(_ event: UnsafeMutablePointer<GdkEvent>) -> Bool {
    var x = 0.0, y = 0.0
    _ = gdk_event_get_coords(event, &x, &y)
    return x >= 0 && y >= 0 && x < placement.width && y < placement.height
  }

  func update(_ node: Element, visible: Rect, enabled: Bool) {
    func label(_ element: Element) -> String {
      if !element.props.accessibilityLabel.isEmpty { return element.props.accessibilityLabel }
      if !element.props.text.isEmpty { return element.props.text }
      return element.children.map(label).filter { !$0.isEmpty }.joined(separator: " ")
    }
    let label = label(node)
    if name != label {
      name = label
      atk_object_set_name(gtk_widget_get_accessible(widget), label)
    }
    if help != node.props.help {
      help = node.props.help
      gtk_widget_set_tooltip_text(widget, node.props.help.isEmpty ? nil : node.props.help)
    }
    if placement != visible {
      placement = visible
      gtk_fixed_move(host, widget, pixels(visible.minX), pixels(visible.minY))
      gtk_widget_set_size_request(widget, pixels(visible.width), pixels(visible.height))
    }
    let sensitive: gboolean = enabled ? 1 : 0
    if gtk_widget_get_sensitive(widget) != sensitive { gtk_widget_set_sensitive(widget, sensitive) }
    let shown: gboolean = !visible.isEmpty && !node.props.accessibilityHidden ? 1 : 0
    if gtk_widget_get_visible(widget) != shown { gtk_widget_set_visible(widget, shown) }
  }
}

private final class Editor {
  let input: Widget
  private let widget: Widget
  private let host: UnsafeMutablePointer<GtkFixed>
  private let id: NodeID
  private let multiline: Bool
  private let editable: UnsafeMutableRawPointer
  private weak var backend: LinuxDrawingBackend?
  private var signals: [(UnsafeMutableRawPointer, gulong)] = []
  private var style: String?
  private let provider = gtk_css_provider_new()!
  private var placement = Rect.zero
  private var label: String?

  init?(_ id: NodeID, props: NodeProps, host: UnsafeMutablePointer<GtkFixed>, backend: LinuxDrawingBackend) {
    self.id = id
    self.host = host
    self.backend = backend
    multiline = props.multiline
    guard let input = props.multiline ? gtk_text_view_new() : gtk_entry_new() else { return nil }
    self.input = input
    if props.multiline {
      guard let scrolled = gtk_scrolled_window_new(nil, nil),
            let buffer = gtk_text_view_get_buffer(typed(input, GtkTextView.self)) else {
        g_object_ref_sink(input)
        g_object_unref(input)
        return nil
      }
      widget = scrolled
      editable = UnsafeMutableRawPointer(buffer)
      g_object_ref(editable)
      g_object_ref_sink(input)
      gtk_scrolled_window_set_policy(typed(scrolled, GtkScrolledWindow.self), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      gtk_container_add(typed(scrolled, GtkContainer.self), input)
      gtk_text_view_set_wrap_mode(typed(input, GtkTextView.self), GTK_WRAP_WORD_CHAR)
      gtk_widget_show(input)
    } else {
      widget = input
      editable = UnsafeMutableRawPointer(input)
      gtk_entry_set_has_frame(typed(input, GtkEntry.self), 0)
      gtk_entry_set_width_chars(typed(input, GtkEntry.self), 1)
      gtk_entry_set_visibility(typed(input, GtkEntry.self), props.secure ? 0 : 1)
    }
    g_object_ref_sink(widget)
    gtk_fixed_put(host, widget, 0, 0)
    gtk_style_context_add_provider(gtk_widget_get_style_context(input), OpaquePointer(provider), 700)
    let data = Unmanaged.passUnretained(self).toOpaque()
    let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
      guard let data else { return }
      let editor = Unmanaged<Editor>.fromOpaque(data).takeUnretainedValue()
      editor.backend?.sendText(editor.text(), from: editor.id)
    }
    signals.append((editable, g_signal_connect_data(editable, "changed", unsafeBitCast(changed, to: GCallback.self), data, nil, .init(rawValue: 0))))
    let key: @convention(c) (Widget?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      let editor = Unmanaged<Editor>.fromOpaque(data).takeUnretainedValue()
      return editor.backend?.key(event.pointee, id: editor.id) ?? 0
    }
    signals.append((UnsafeMutableRawPointer(input),
                    g_signal_connect_data(input, "key-press-event", unsafeBitCast(key, to: GCallback.self), data, nil, .init(rawValue: 0))))
    let focus: @convention(c) (Widget?, UnsafeMutablePointer<GdkEventFocus>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
      guard let event, let data else { return 0 }
      let editor = Unmanaged<Editor>.fromOpaque(data).takeUnretainedValue()
      editor.backend?.focus(editor.id, gained: event.pointee.in != 0)
      return 0
    }
    for signal in ["focus-in-event", "focus-out-event"] {
      signals.append((UnsafeMutableRawPointer(input),
                      g_signal_connect_data(input, signal, unsafeBitCast(focus, to: GCallback.self), data, nil, .init(rawValue: 0))))
    }
  }

  deinit {
    for (object, signal) in signals where g_signal_handler_is_connected(object, signal) != 0 {
      g_signal_handler_disconnect(object, signal)
    }
    gtk_style_context_remove_provider(gtk_widget_get_style_context(input), OpaquePointer(provider))
    g_object_unref(provider)
    gtk_widget_destroy(widget)
    if multiline {
      g_object_unref(input)
      g_object_unref(editable)
    }
    g_object_unref(widget)
  }

  func update(_ props: NodeProps, visible: Rect, background: SwiftUIRuntime.Color, label: String) {
    if text() != props.text {
      if multiline {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(typed(input, GtkTextView.self)), props.text, -1)
      } else {
        gtk_entry_set_text(typed(input, GtkEntry.self), props.text)
      }
    }
    if !multiline {
      let entry = typed(input, GtkEntry.self)
      let placeholder = gtk_entry_get_placeholder_text(entry).map { String(cString: $0) } ?? ""
      if placeholder != props.placeholder { gtk_entry_set_placeholder_text(entry, props.placeholder) }
      let plain: gboolean = props.secure ? 0 : 1
      if gtk_entry_get_visibility(entry) != plain { gtk_entry_set_visibility(entry, plain) }
    }
    let name = label.isEmpty ? props.placeholder : label
    if self.label != name {
      self.label = name
      atk_object_set_name(gtk_widget_get_accessible(input), name)
    }
    let font = props.font ?? .body
    let fontFamily = font.family == "Consolas" ? "monospace" : font.family == "Segoe UI" ? "sans-serif" : font.family
    let family = fontFamily.replacingOccurrences(of: "\"", with: "")
    let foreground = props.foreground ?? .black
    func css(_ c: SwiftUIRuntime.Color) -> String {
      "rgba(\(Int(c.red * 255)),\(Int(c.green * 255)),\(Int(c.blue * 255)),\(c.opacity))"
    }
    let css = "entry, textview, textview text { border: none; box-shadow: none; outline: none; padding: 0; min-height: 0; min-width: 0; font-family: \"\(family)\"; font-size: \(font.size)px; font-weight: \(Int(font.weight.value)); color: \(css(foreground)); background: \(css(background)); }"
    if css != style {
      style = css
      gtk_css_provider_load_from_data(provider, css, -1, nil)
    }
    if placement != visible {
      placement = visible
      gtk_fixed_move(host, widget, pixels(visible.minX), pixels(visible.minY))
      gtk_widget_set_size_request(widget, pixels(visible.width), pixels(visible.height))
    }
    if gtk_widget_get_opacity(widget) != props.opacity { gtk_widget_set_opacity(widget, props.opacity) }
    let sensitive: gboolean = props.enabled ? 1 : 0
    if gtk_widget_get_sensitive(widget) != sensitive { gtk_widget_set_sensitive(widget, sensitive) }
    let shown: gboolean = visible.isEmpty ? 0 : 1
    if gtk_widget_get_visible(widget) != shown { gtk_widget_set_visible(widget, shown) }
  }

  private func text() -> String {
    if multiline {
      let buffer = gtk_text_view_get_buffer(typed(input, GtkTextView.self))
      var start = GtkTextIter(), end = GtkTextIter()
      gtk_text_buffer_get_bounds(buffer, &start, &end)
      guard let text = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
      defer { g_free(text) }
      return String(cString: text)
    }
    return gtk_entry_get_text(typed(input, GtkEntry.self)).map { String(cString: $0) } ?? ""
  }
}
#endif
