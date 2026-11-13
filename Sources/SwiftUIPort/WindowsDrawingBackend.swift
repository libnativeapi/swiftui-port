#if os(Windows)
  import Foundation
  import NativeAPI
  import SwiftUIRuntime
  import CSwiftUIWindows

  /// Generic SwiftUI drawing hosted by nativeapi. Decorative nodes share a
  /// display list; buttons keep native Windows handles and native activation.
  public final class WindowsDrawingBackend: RenderBackend {
    /// Call before creating any native windows when embedding the renderer.
    /// App.main configures per-monitor DPI awareness automatically.
    public static func prepareApplication() { sui_prepare_application() }

    public var tapHandler: ((NodeID) -> Void)?
    public var transactionHandler: ((() -> Void) -> Void)?
    public var interactionHandler: ((NodeID, Renderer.Interaction) -> Void)?
    public var inputHandler: ((NodeID?, Int, CGPoint, Int, EventModifiers, String) -> Bool)?
    private let schedulesUpdates: Bool
    private let tracesFrames = ProcessInfo.processInfo.environment["SWIFTUI_PORT_TRACE_PATH"] != nil
    private var deliveringUpdate = false
    private var pendingRender: (() -> Void)?
    private var pendingPointer: (() -> Void)?
    private var updateListener: ListenerId?
    private var pendingEvents: [() -> Void] = []
    private var modalControls: Set<NodeID>?
    private var controlLabels: [NodeID: String] = [:]
    private var controlHitRadii: [NodeID: Double] = [:]
    private var desiredFocus: NodeID?
    private var edits: [NodeID: UnsafeMutableRawPointer] = [:]
    private var root: Element?
    private struct AnimatedValues: Equatable {
      let rotation, scaleX, scaleY, opacity, offsetX, offsetY: Double
      init(_ p: NodeProps) {
        rotation = p.rotation
        scaleX = p.scaleX
        scaleY = p.scaleY
        opacity = p.opacity
        offsetX = p.offsetX
        offsetY = p.offsetY
      }
    }
    private struct Motion {
      let from: AnimatedValues
      let frame: Rect
      let animation: Animation
      let start: TimeInterval
    }
    private var motions: [NodeID: Motion] = [:]
    private var previous: [NodeID: AnimatedValues] = [:]
    public var onResize: ((SwiftUIRuntime.Size) -> Void)?
    public private(set) var lastTimings: [String: Double] = [:]
    public private(set) var publicationCount = 0
    public private(set) var fullPublicationCount = 0
    public private(set) var nativeHoverEventCount = 0
    public private(set) var nativeHoverEnterCount = 0
    public private(set) var totalPointerQueryMilliseconds: Double = 0
    public var totalPaintTimings: [String: Double] {
      guard let surface else { return [:] }
      let stats = sui_surface_total_paint_stats(surface)
      return ["raster": stats.raster_ms, "blit": stats.blit_ms, "count": Double(stats.paints)]
    }
    public var lastReusedPixels: Int64 { surface.map { sui_surface_reused_pixels($0) } ?? 0 }
    public var lastPaintTimings: [String: Double] {
      guard let surface else { return [:] }
      let stats = sui_surface_paint_stats(surface)
      return ["raster": stats.raster_ms, "blit": stats.blit_ms, "count": Double(stats.paints)]
    }
    private let window: NativeAPI.Window
    private let content: NativeAPI.View
    private var surface: UnsafeMutableRawPointer?
    private var listener: ListenerId?
    private var buttons: [NodeID: (view: NativeAPI.Button, listener: ListenerId)] = [:]

    public init?(window: NativeAPI.Window, schedulesUpdates: Bool = false) {
      guard let content = window.contentView, let handle = content.nativeObject else { return nil }
      self.schedulesUpdates = schedulesUpdates
      self.window = window
      self.content = content
      content.setLayout(.absolute)
      surface = sui_surface_create(
        handle,
        { context, id, event in
          guard let context else { return }
          let backend = Unmanaged<WindowsDrawingBackend>.fromOpaque(context).takeUnretainedValue()
          if event == 1 || event == 2 { backend.nativeHoverEventCount += 1 }
          if event == 1 { backend.nativeHoverEnterCount += 1 }
          if backend.schedulesUpdates && (event == 1 || event == 2) {
            backend.queuePointer()
            return
          }
          let interaction: Renderer.Interaction
          switch event {
          case 1: interaction = .hover(true)
          case 2: interaction = .hover(false)
          case 3: interaction = .pressed(true)
          case 4: interaction = .pressed(false)
          case 5: interaction = .focus(true)
          default: interaction = .focus(false)
          }
          backend.enqueue { [weak backend] in
            guard let backend else { return }
            let node = NodeID(rawValue: Int(id))
            if event == 5 || event == 6 {
              // Several Tab/focus changes can arrive before the next render.
              // An obsolete gain must not pull focus back to its old HWND.
              let focused =
                backend.edits[node].map { sui_control_focused($0) != 0 }
                ?? backend.buttons[node]?.view.isFocused ?? false
              guard focused == (event == 5) else { return }
            }
            backend.interactionHandler?(node, interaction)
          }
        }, Unmanaged.passUnretained(self).toOpaque(), content.nativeHandle)
      guard let surface else { return nil }
      sui_surface_input(
        surface,
        { context, id, event, x, y, value, modifiers in
          guard let context else { return 0 }
          let backend = Unmanaged<WindowsDrawingBackend>.fromOpaque(context).takeUnretainedValue()
          if backend.schedulesUpdates {
            if event == 1 || event == 10 {
              backend.queuePointer(fallback: CGPoint(x: x, y: y))
              return 1
            }
            if event == 5 {
              backend.enqueue { [weak backend] in
                _ = backend?.inputHandler?(
                  id == 0 ? nil : NodeID(rawValue: Int(id)), 5,
                  CGPoint(x: x, y: y), Int(value), EventModifiers(rawValue: Int(modifiers)), "")
              }
              return 1
            }
            if event == 8 {
              if !backend.motions.isEmpty { _ = backend.content.requestUpdate() }
              return 0
            }
            // Preserve press/key/text ordering relative to earlier pointer input.
            if [2, 3, 4, 6, 7, 9].contains(Int(event)) { backend.drainInput() }
          }
          if event == 12 {
            if let root = backend.root { backend.didRender(root) }
            return 0
          }
          if event == 11 {
            let jobs = backend.pendingEvents
            backend.pendingEvents.removeAll()
            if let transaction = backend.transactionHandler {
              transaction { jobs.forEach { $0() } }
            } else {
              jobs.forEach { $0() }
            }
            return 0
          }
          if event == 8 {
            backend.tick()
            return 0
          }
          if event == 10, let point = backend.pointerLocation(fallback: .zero) {
            // Leaving a native scrolling container for one of its children is
            // not leaving the SwiftUI surface. Reconcile the current hit path.
            return backend.inputHandler?(nil, 1, point, 0, [], "") == true ? 1 : 0
          }
          var text = ""
          if event == 7, let edit = backend.edits[NodeID(rawValue: Int(id))] {
            var bytes = [CChar](repeating: 0, count: Int(sui_edit_text(edit, nil, 0)))
            _ = sui_edit_text(edit, &bytes, Int32(bytes.count))
            text = String(cString: bytes)
          }
          return backend.inputHandler?(
            id == 0 ? nil : NodeID(rawValue: Int(id)), Int(event), CGPoint(x: x, y: y), Int(value),
            EventModifiers(rawValue: Int(modifiers)), text) == true ? 1 : 0
        })
      if schedulesUpdates {
        updateListener = content.addListener { [weak self] event in
          if case .updating = event { self?.deliverUpdate() }
        }
      }
      listener = window.addListener { [weak self] event in
        // Window's resize event includes decorations; the renderer needs client size.
        if case .resized = event, let self {
          let size = self.window.contentSize
          self.onResize?(SwiftUIRuntime.Size(width: size.width, height: size.height))
        }
      }
    }
    deinit {
      content.cancelUpdate()
      if let updateListener { _ = content.removeListener(updateListener) }
      if let listener { _ = window.removeListener(listener) }
      for id in Array(buttons.keys) { removeButton(id) }
      if let surface { sui_surface_destroy(surface) }
    }

    private struct TextMeasurementKey: Hashable {
      let text: String, family: String
      let size: Double, weight: Double
    }
    private static var textMeasurements: [TextMeasurementKey: SwiftUIRuntime.Size] = [:]

    public static func measureText(_ text: String, font: Font) -> SwiftUIRuntime.Size {
      let key = TextMeasurementKey(
        text: text, family: font.family, size: Double(font.size), weight: font.weight.value)
      if let cached = textMeasurements[key] { return cached }
      let measured = sui_measure_text(text, font.family, Double(font.size), font.weight.value)
      let size = SwiftUIRuntime.Size(width: measured.width, height: measured.height)
      // Bound cache growth when applications display arbitrary edited text.
      if textMeasurements.count >= 10000 { textMeasurements.removeAll(keepingCapacity: true) }
      textMeasurements[key] = size
      return size
    }

    /// Drawing is published atomically from didRender after diffing assigns IDs.
    public func perform(_ commands: [RenderCommand]) {}
    public func didMeasureRender(_ timings: [String: Double]) {
      guard tracesFrames, let surface else { return }
      for (stage, name) in ["evaluate", "environment", "layout", "finalize", "diff",
                            "backend", "scroll.translate"].enumerated() {
        if let value = timings[name] { sui_surface_trace_duration(surface, Int32(stage), value) }
      }
      for (stage, name) in ["prepare", "draw", "controls", "publish"].enumerated() {
        if let value = lastTimings[name] { sui_surface_trace_duration(surface, Int32(stage + 10), value) }
      }
    }
    public func didRender(_ root: Element) {
      guard let surface else { return }
      fullPublicationCount += 1
      let started = Date.timeIntervalSinceReferenceDate
      let now = Date.timeIntervalSinceReferenceDate
      var current: [NodeID: AnimatedValues] = [:]
      var live = Set<NodeID>()
      var liveEdits = Set<NodeID>()
      var hasModal = false
      var hasFocusRequest = false
      func animate(_ node: Element, inherited: Animation?) {
        if node.kind == .textField { liveEdits.insert(node.id) }
        if node.kind == .styledButton || node.kind == .button { live.insert(node.id) }
        hasModal =
          hasModal || node.props.accessibilityTraits & AccessibilityTraits.isModal.rawValue != 0
        hasFocusRequest = hasFocusRequest || node.props.focusRequested
        let values = AnimatedValues(node.props)
        current[node.id] = values
        let animation = node.props.animation ?? inherited
        if let old = previous[node.id], let animation, animation.duration > 0,
          old != values
        {
          motions[node.id] = Motion(
            from: old, frame: node.frame, animation: animation, start: now + animation.delay)
        }
        node.children.forEach { animate($0, inherited: animation) }
      }
      animate(root, inherited: nil)
      previous = current
      motions = motions.filter { current[$0.key] != nil }
      self.root = root
      modalControls = nil
      func modal(_ node: Element) {
        if node.props.accessibilityTraits & AccessibilityTraits.isModal.rawValue != 0 {
          func ids(_ node: Element) -> [NodeID] { [node.id] + node.children.flatMap(ids) }
          modalControls = Set(ids(node))
        }
        node.children.forEach(modal)
      }
      if hasModal { modal(root) }
      desiredFocus = nil
      func focusTarget(_ node: Element) {
        if node.props.focusRequested {
          func controls(_ node: Element) -> [NodeID] {
            if node.kind == .button || node.kind == .styledButton || node.kind == .textField {
              return [node.id]
            }
            return node.children.flatMap(controls)
          }
          let candidates = controls(node)
          desiredFocus =
            candidates.first(where: { id in
              if let edit = edits[id] { return sui_control_focused(edit) != 0 }
              return buttons[id]?.view.isFocused == true
            }) ?? candidates.first
        }
        node.children.forEach(focusTarget)
      }
      if hasFocusRequest { focusTarget(root) }
      for id in Set(buttons.keys).subtracting(live) { removeButton(id) }
      for id in Set(edits.keys).subtracting(liveEdits) {
        if let edit = edits.removeValue(forKey: id) { sui_edit_destroy(surface, edit) }
      }
      sui_surface_begin(surface)
      lastTimings["prepare"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
      publish(root, on: surface)
    }

    public func didScroll(_ root: Element) {
      guard motions.isEmpty else {
        didRender(root)
        return
      }
      guard let surface else { return }
      self.root = root
      // Scrolling does not change live controls, animation values, modal state
      // or focus requests. Keep those registrations and publish new geometry.
      lastTimings["prepare"] = 0
      sui_surface_begin(surface)
      publish(root, on: surface, geometryOnly: true)
    }

    private func publish(_ root: Element, on surface: UnsafeMutableRawPointer, geometryOnly: Bool = false) {
      publicationCount += 1
      var started = Date.timeIntervalSinceReferenceDate
      draw(root, clip: root.frame)
      lastTimings["draw"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
      started = Date.timeIntervalSinceReferenceDate
      sui_controls_begin(surface)
      updateButtons(root, clip: root.frame, geometryOnly: geometryOnly)
      lastTimings["controls"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
      started = Date.timeIntervalSinceReferenceDate
      sui_surface_end(surface)
      lastTimings["publish"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
      for (stage, name) in ["reuse", "order", "commands", "geometry", "damage", "invalidate"]
        .enumerated()
      {
        lastTimings["publish.\(name)"] = sui_surface_publish_time(surface, Int32(stage))
      }
    }

    /// Native activation for integration tests or accessibility adapters. It is
    /// scoped to a retained control, never to the user's keyboard or pointer.
    public func activate(_ id: NodeID) {
      if let handle = buttons[id]?.view.nativeObject {
        sui_button_activate(handle)
        if let surface { sui_surface_flush(surface) }
      }
    }
    /// Programmatic editing and pointer events are scoped to this surface's HWND.
    public func replaceText(_ id: NodeID, with text: String) {
      if let edit = edits[id] {
        sui_edit_replace_text(edit, text)
        if let surface { sui_surface_flush(surface) }
      }
    }
    public func pointer(event: Int, at point: CGPoint, value: Int = 0) {
      if let surface { sui_surface_pointer(surface, Int32(event), point.x, point.y, Int32(value)) }
    }
    public func pointerLocation(fallback: CGPoint) -> CGPoint? {
      let started = Date.timeIntervalSinceReferenceDate
      defer {
        totalPointerQueryMilliseconds += (Date.timeIntervalSinceReferenceDate - started) * 1000
      }
      let point = DisplayManager.shared.getCursorPosition()
      guard WindowManager.shared.getWindowAtPoint(point, excludedWindowId: 0)?.id == window.id
      else { return nil }
      let bounds = window.contentBounds
      let local = CGPoint(x: point.x - bounds.x, y: point.y - bounds.y)
      guard local.x >= 0, local.y >= 0, local.x < bounds.width, local.y < bounds.height else {
        return nil
      }
      return local
    }
    public func nativeButton(_ id: NodeID) -> NativeAPI.Button? { buttons[id]?.view }
    public func advanceFocus(from id: NodeID?, backward: Bool = false) {
      if let surface {
        sui_surface_focus_next(
          surface, id.flatMap { buttons[$0]?.view.nativeObject }, backward ? 1 : 0)
      }
    }
    func focusInitialControl() {
      // The top-level HWND initially owns focus. Put it on the first available
      // control so Tab works before the user has clicked anything.
      if !buttons.values.contains(where: { $0.view.isFocused }) { advanceFocus(from: nil) }
    }

    public func requestRender(_ render: @escaping () -> Void) -> Bool {
      guard schedulesUpdates, !deliveringUpdate else { return false }
      pendingRender = render
      if content.requestUpdate() { return true }
      pendingRender = nil
      return false
    }
    private func queuePointer(fallback: CGPoint = .zero) {
      pendingPointer = { [weak self] in
        guard let self else { return }
        let point = self.pointerLocation(fallback: fallback)
        _ = self.inputHandler?(nil, point == nil ? 10 : 1, point ?? fallback, 0, [], "")
      }
      // A move over unchanged content must not consume the next publication
      // slot. Resolve that cheap hit path now; state changes still request one
      // deferred render. Preserve ordering when wheel/actions are pending.
      if pendingEvents.isEmpty && pendingRender == nil && !deliveringUpdate {
        drainInput()
      } else if !content.requestUpdate() {
        drainInput()
      }
    }
    private func drainInput() {
      let jobs = pendingEvents
      pendingEvents.removeAll(keepingCapacity: true)
      let pointer = pendingPointer
      pendingPointer = nil
      let run = {
        jobs.forEach { $0() }
        pointer?()
      }
      if let transaction = transactionHandler { transaction(run) } else { run() }
    }
    private func deliverUpdate() {
      if let surface { sui_surface_trace_update(surface, 1) }
      defer { if let surface { sui_surface_trace_update(surface, 0) } }
      deliveringUpdate = true
      defer { deliveringUpdate = false }
      let publications = publicationCount
      drainInput()
      let render = pendingRender
      pendingRender = nil
      render?()
      if publications == publicationCount { tick() }
      if !motions.isEmpty { _ = content.requestUpdate() }
    }
    private func enqueue(_ action: @escaping () -> Void) {
      let schedule = pendingEvents.isEmpty
      pendingEvents.append(action)
      if schedulesUpdates {
        if !content.requestUpdate() { drainInput() }
      } else if schedule, let surface {
        sui_surface_schedule(surface)
      }
    }
    private func tick() {
      // The C bridge services Dispatch without consuming NativeAPI WM_QUIT.
      guard !motions.isEmpty, let surface, let root else { return }
      let now = Date.timeIntervalSinceReferenceDate
      motions = motions.filter {
        $0.value.animation.repeats || now < $0.value.start + $0.value.animation.duration
      }
      guard
        motions.values.contains(where: {
          let visible = $0.frame.intersection(root.frame)
          return visible.width > 0 && visible.height > 0
        })
      else { return }
      sui_surface_begin(surface)
      draw(root, clip: root.frame)
      sui_surface_end(surface)
    }
    private func updateButtons(
      _ node: Element, allowed: Bool = true, clip: Rect,
      background: SwiftUIRuntime.Color = .white, nativeClip: Rect? = nil,
      geometryOnly: Bool = false
    ) {
      let allowed = allowed && node.props.hitTesting
      let controlAllowed = allowed && (modalControls?.contains(node.id) ?? true)
      let clip = node.props.clipped ? clip.intersection(node.frame) : clip
      var nativeClip = nativeClip.map { node.props.clipped ? $0.intersection(node.frame) : $0 }
      let background = node.props.background.flatMap { $0.opacity > 0.99 ? $0 : nil } ?? background
      let wantsFocus = desiredFocus == node.id
      let viewport = node.frame.intersection(clip)
      let inViewport =
        node.props.visible && controlAllowed && viewport.width > 0 && viewport.height > 0
      // Keep child HWND coordinates stable while the ScrollView's content moves.
      // The shared framebuffer remains in surface coordinates at native DPI.
      let grouped = node.kind == .scroll && node.children.first != nil
      if grouped, let surface, let child = node.children.first {
        let r = child.frame
        let visible = node.props.visible ? clip.intersection(node.frame) : .zero
        sui_controls_push(
          surface, Int64(node.id.rawValue), r.minX, r.minY, r.width, r.height,
          visible.minX, visible.minY, visible.width, visible.height)
        // The parent viewport already clips this content. Only additional
        // clipping inside it belongs in each control's local hit region.
        nativeClip = r
      }
      defer { if grouped, let surface { sui_controls_pop(surface) } }
      if node.kind == .styledButton || node.kind == .button, buttons[node.id] != nil || inViewport {
        let retained = buttons[node.id] != nil
        if buttons[node.id] == nil {
          guard let button = NativeAPI.Button.create(label(node)), let handle = button.nativeObject
          else {
            fatalError("nativeapi failed to create a button")
          }
          let styled = node.kind == .styledButton
          if let surface {
            sui_surface_button(
              surface, handle, Int64(node.id.rawValue), styled ? 1 : 0, button.nativeHandle)
          }
          let id = node.id
          let listener = button.addListener { [weak self] event in
            if case .buttonClicked = event {
              self?.enqueue { [weak self] in self?.tapHandler?(id) }
            }
          }
          buttons[id] = (button, listener)
        }
        let button = buttons[node.id]!.view
        let r = node.frame
        if inViewport || nativeClip != nil, let surface, let handle = button.nativeObject {
          sui_control_frame(surface, handle, r.minX, r.minY, r.width, r.height)
        }
        // A scroll-only publication preserves state and labels. Native parent
        // clipping handles visibility inside a scroll group; ungrouped controls
        // still need visibility refreshed when their viewport changes.
        if !geometryOnly || !retained {
          let enabled = node.props.enabled && controlAllowed
          if button.isEnabled != enabled { button.setEnabled(enabled) }
          let title = label(node)
          if controlLabels[node.id] != title {
            button.setText(title)
            controlLabels[node.id] = title
          }
          func hitRadius(_ element: Element) -> Double {
            max(element.props.hitRadius, element.children.map(hitRadius).max() ?? 0)
          }
          controlHitRadii[node.id] = hitRadius(node)
        }
        if !geometryOnly || !retained || nativeClip == nil {
          let visible = node.props.visible && controlAllowed && (nativeClip != nil || inViewport)
          if button.isVisible != visible { button.setVisible(visible) }
        }
        if let surface, let handle = button.nativeObject {
          sui_control_tab_visible(surface, handle, inViewport ? 1 : 0)
          let visible =
            node.props.visible && controlAllowed ? r.intersection(nativeClip ?? clip) : .zero
          sui_button_update(
            surface, handle, controlHitRadii[node.id] ?? 0, node.props.help,
            visible.minX - r.minX, visible.minY - r.minY, visible.width, visible.height)
        }
        if wantsFocus && !button.isFocused && node.props.enabled && inViewport {
          button.focus()
        }
      }
      if node.kind == .textField, let surface, edits[node.id] != nil || inViewport {
        if edits[node.id] == nil {
          edits[node.id] = sui_edit_create(
            surface, Int64(node.id.rawValue), node.props.multiline ? 1 : 0,
            node.props.secure ? 1 : 0)
        }
        if let edit = edits[node.id] {
          let p = node.props
          let r = node.frame
          let font = p.font ?? .body
          sui_edit_update(
            surface, edit, p.text, p.placeholder, r.minX, r.minY, r.width, r.height, font.family,
            Double(font.size), font.weight.value, (p.foreground ?? .black).argb, background.argb,
            p.enabled && controlAllowed ? 1 : 0, wantsFocus ? 1 : 0)
          sui_control_opacity(edit, p.opacity)
          let visible = inViewport ? r.intersection(nativeClip ?? clip) : .zero
          sui_control_clip(
            edit, visible.minX - r.minX, visible.minY - r.minY, visible.width, visible.height)
        }
      }
      for child in orderedChildren(node) {
        updateButtons(
          child, allowed: allowed, clip: clip, background: background, nativeClip: nativeClip,
          geometryOnly: geometryOnly)
      }
    }
    private func label(_ node: Element) -> String {
      if !node.props.accessibilityLabel.isEmpty { return node.props.accessibilityLabel }
      if !node.props.text.isEmpty { return node.props.text }
      return node.children.map(label).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func removeButton(_ id: NodeID) {
      guard let button = buttons.removeValue(forKey: id) else { return }
      controlLabels.removeValue(forKey: id)
      controlHitRadii.removeValue(forKey: id)
      _ = button.view.removeListener(button.listener)
      if let surface, let handle = button.view.nativeObject {
        sui_surface_remove_button(surface, handle)
      }
      button.view.dispose()
    }
    private func draw(_ node: Element, clip: Rect, transformedAncestor: Bool = false) {
      guard let surface, node.props.visible else { return }
      var p = node.props
      let r = node.frame
      var translated = false
      if let motion = motions[node.id] {
        let elapsed =
          max(0, Date.timeIntervalSinceReferenceDate - motion.start) / motion.animation.duration
        var fraction =
          motion.animation.repeats ? elapsed.truncatingRemainder(dividingBy: 1) : min(1, elapsed)
        if motion.animation.autoreverses && Int(elapsed) % 2 == 1 { fraction = 1 - fraction }
        func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        p.rotation = mix(motion.from.rotation, p.rotation)
        p.scaleX = mix(motion.from.scaleX, p.scaleX)
        p.scaleY = mix(motion.from.scaleY, p.scaleY)
        p.opacity = mix(motion.from.opacity, p.opacity)
        let dx = mix(motion.from.offsetX, p.offsetX) - p.offsetX
        let dy = mix(motion.from.offsetY, p.offsetY) - p.offsetY
        if dx != 0 || dy != 0 {
          sui_surface_translation(surface, dx, dy)
          translated = true
        }
      }
      let transformed = p.rotation != 0 || p.scaleX != 1 || p.scaleY != 1
      let canCull = !transformedAncestor && !transformed && !translated
      let clip = p.clipped && canCull ? clip.intersection(r) : clip
      if canCull && p.clipped && (clip.width <= 0 || clip.height <= 0) { return }
      if canCull && node.children.isEmpty && p.shadows.isEmpty
        && (node.kind == .text || node.kind == .image || node.kind == .shape)
      {
        let margin = max(2, p.borderWidth)
        let ink = Rect(
          x: r.minX - margin, y: r.minY - margin,
          width: r.width + margin * 2, height: r.height + margin * 2)
        let visible = ink.intersection(clip)
        if visible.width <= 0 || visible.height <= 0 { return }
      }
      if transformed {
        sui_surface_transform(
          surface, r.minX + r.width / 2, r.minY + r.height / 2, p.rotation, p.scaleX, p.scaleY)
      }
      func vector(
        _ path: Path, fill: SwiftUIRuntime.Color = .clear, stroke: SwiftUIRuntime.Color = .clear,
        width: Double = 0, clip: Bool = false
      ) {
        path.commands.withUnsafeBufferPointer { buffer in
          sui_surface_path(
            surface, buffer.baseAddress, Int32(buffer.count), fill.opacity(p.opacity).argb,
            stroke.opacity(p.opacity).argb, width, clip ? 1 : 0)
        }
      }
      let bounds = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
      for shadow in p.shadows where shadow.color.opacity > 0 {
        // A finite layered approximation, not a blur filter. It never changes
        // the view's layout or native hit rectangle.
        let steps = max(1, min(16, Int(ceil(shadow.radius))))
        for step in (0..<steps).reversed() {
          let spread = Double(step) / 2
          sui_surface_shape(
            surface, r.minX + shadow.x - spread, r.minY + shadow.y - spread,
            r.width + spread * 2, r.height + spread * 2, p.cornerRadius + spread,
            shadow.color.opacity(p.opacity / Double(steps)).argb, 0, 0)
        }
      }
      if p.clipped { sui_surface_clip(surface, r.minX, r.minY, r.width, r.height, p.cornerRadius) }
      if let clip = node.clipPathBuilder {
        vector(
          clip(CGRect(origin: .zero, size: bounds.size)).transformed(x: r.minX, y: r.minY),
          clip: true)
      }
      if let shape = node.pathBuilder {
        vector(
          shape(bounds), fill: p.background ?? .clear, stroke: p.borderColor, width: p.borderWidth)
      } else if node.kind == .path {
        vector(
          p.path.transformed(x: r.minX, y: r.minY), fill: p.background ?? .clear,
          stroke: p.borderColor, width: p.borderWidth)
      } else if (p.background?.opacity ?? 0) > 0 || p.borderWidth > 0 && p.borderColor.opacity > 0 {
        sui_surface_shape(
          surface, r.minX, r.minY, r.width, r.height, p.cornerRadius,
          (p.background ?? .clear).opacity(p.opacity).argb, p.borderColor.opacity(p.opacity).argb,
          p.borderWidth)
      }
      if node.kind == .gradient, let gradient = p.gradient {
        let colors = gradient.colors.map { $0.opacity(p.opacity).argb }
        colors.withUnsafeBufferPointer { buffer in
          sui_surface_gradient(
            surface, r.minX, r.minY, r.width, r.height, gradient.start.x, gradient.start.y,
            gradient.end.x, gradient.end.y, buffer.baseAddress, Int32(buffer.count))
        }
      }
      if node.kind == .image {
        if p.imagePath.lowercased().hasSuffix(".svg"), let image = VectorImage.load(p.imagePath) {
          let sx = r.width / image.bounds.width
          let sy = r.height / image.bounds.height
          let scale = min(sx, sy)
          for path in image.paths {
            vector(
              path.transformed(
                x: r.minX + (r.width - image.bounds.width * scale) / 2 - image.bounds.minX * scale,
                y: r.minY + (r.height - image.bounds.height * scale) / 2 - image.bounds.minY
                  * scale, sx: scale, sy: scale), fill: p.foreground ?? .black)
          }
        } else {
          sui_surface_image(surface, p.imagePath, r.minX, r.minY, r.width, r.height)
        }
      }
      if node.kind == .text {
        let font = p.font ?? .body
        let text = p.renderedText ?? p.text
        sui_surface_text(
          surface, r.minX, r.minY, r.width, r.height, text, font.family,
          Double(font.size), font.weight.value, p.lineSpacing,
          (p.foreground ?? .black).opacity(p.opacity).argb)
      }
      let cacheScroll =
        node.kind == .scroll && canCull && p.clipped && p.cornerRadius == 0
        && node.clipPathBuilder == nil && motions.isEmpty && node.children.first != nil
      if cacheScroll, let child = node.children.first {
        // The bridge verifies translated paint commands, clips and backdrop
        // before copying pixels; opaque/custom layout does not need guessing.
        sui_surface_scroll_begin(
          surface, Int64(node.id.rawValue), 0,
          clip.minX, clip.minY, clip.width, clip.height, child.frame.minX, child.frame.minY)
      }
      for child in orderedChildren(node) {
        draw(
          child, clip: clip, transformedAncestor: transformedAncestor || transformed || translated)
      }
      if node.kind == .scroll, p.showsScrollIndicators, let child = node.children.first {
        let color = (p.foreground ?? .gray).opacity(0.3).argb
        if child.frame.height > r.height && r.height > 0 {
          let height = max(20, r.height * r.height / child.frame.height)
          let y = r.minY + p.scrollOffset.y / (child.frame.height - r.height) * (r.height - height)
          sui_surface_shape(surface, r.maxX - 6, y, 4, height, 2, color, 0, 0)
        }
        if child.frame.width > r.width && r.width > 0 {
          let width = max(20, r.width * r.width / child.frame.width)
          let x = r.minX + p.scrollOffset.x / (child.frame.width - r.width) * (r.width - width)
          sui_surface_shape(surface, x, r.maxY - 6, width, 4, 2, color, 0, 0)
        }
      }
      if cacheScroll { sui_surface_scroll_end(surface) }
      if node.clipPathBuilder != nil { sui_surface_restore(surface) }
      if p.clipped { sui_surface_restore(surface) }
      if transformed { sui_surface_restore(surface) }
      if translated { sui_surface_restore(surface) }
    }
    private func orderedChildren(_ node: Element) -> [Element] {
      let children =
        node.kind == .layer && node.props.layerBehind
        ? Array(node.children.reversed()) : node.children
      guard children.count > 1, children.contains(where: { $0.props.zIndex != 0 }) else {
        return children
      }
      return children.enumerated().sorted(by: {
        $0.element.props.zIndex == $1.element.props.zIndex
          ? $0.offset < $1.offset : $0.element.props.zIndex < $1.element.props.zIndex
      }).map { $0.element }
    }
  }
  extension Rect {
    fileprivate func intersection(_ other: Rect) -> Rect {
      let x = max(minX, other.minX)
      let y = max(minY, other.minY)
      return Rect(
        x: x, y: y, width: max(0, min(maxX, other.maxX) - x),
        height: max(0, min(maxY, other.maxY) - y))
    }
  }
  extension SwiftUIRuntime.Color {
    fileprivate var argb: UInt32 {
      func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
      return byte(opacity) << 24 | byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
  }
#endif
