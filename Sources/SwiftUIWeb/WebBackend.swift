import JavaScriptKit
import SwiftUIRuntime

final class WebBackend: RenderBackend {
  var tapHandler: ((NodeID) -> Void)?
  var needsRenderCommands: Bool { false }

  let document: JSObject
  let host: JSObject
  private let measureContext: JSObject
  private var renderScheduled = false
  private var resizeObserver: JSObject?

  struct Node {
    let dom: JSObject
    let drawing: JSObject?
    let content: JSObject?
    var props: NodeProps?
    var frame: Rect?
    var relativeOpacity: Double?
    var clipPath: String?
    var drawingPath: String?
    var acceptsPointer: Bool?
  }

  private var nodes: [NodeID: Node] = [:]
  // Listeners live for the lifetime of the mounted app.
  private var listeners: [JSClosure] = []
  private var pressedButton: NodeID?
  private var trackingPointer: Int?
  private var composing: NodeID?

  init(document: JSObject, host: JSObject) {
    self.document = document
    self.host = host
    measureContext = document.createElement!("canvas").object!.getContext!("2d").object!
  }

  var size: Size {
    Size(width: host.clientWidth.number ?? 0, height: host.clientHeight.number ?? 0)
  }

  func measureText(_ text: String, _ font: Font) -> Size {
    measureContext.font = .string(font.css)
    let width = measureContext.measureText!(text).object!.width.number ?? 0
    return Size(width: width, height: font.lineHeight)
  }

  func requestRender(_ render: @escaping () -> Void) -> Bool {
    if !renderScheduled {
      renderScheduled = true
      _ = JSObject.global.requestAnimationFrame!(
        JSOneshotClosure { [weak self] _ in
          self?.renderScheduled = false
          render()
          return .undefined
        })
    }
    return true
  }

  func perform(_ commands: [RenderCommand]) {}

  func connect(_ renderer: Renderer) {
    let resize = JSClosure { [weak self, weak renderer] _ in
      if let self { renderer?.resize(to: self.size) }
      return .undefined
    }
    listeners.append(resize)
    let observer = JSObject.global.ResizeObserver.object!.new(resize)
    _ = observer.observe!(host)
    resizeObserver = observer

    listen("click", on: host) { [weak self] event in
      guard let self, let id = self.targetID(event, selector: "button[data-node]") else { return }
      self.tapHandler?(id)
    }
    listen("pointerdown", on: host) { [weak self, weak renderer] event in
      guard let self, event.button.number == 0, event.isPrimary.boolean == true else { return }
      self.trackingPointer = event.pointerId.number.map { Int($0) }
      if let id = self.targetID(event, selector: "button[data-node]") {
        self.pressedButton = id
        renderer?.interact(id, .pressed(true))
      } else if self.targetID(event, selector: "input[data-node], textarea[data-node]") == nil,
        let id = self.targetID(event)
      {
        renderer?.input(id: id, event: 2, point: self.point(event))
      }
    }
    listen("pointermove", on: document) { [weak self, weak renderer] event in
      guard let self, event.isPrimary.boolean == true,
        self.trackingPointer != nil || self.host.contains!(event.target).boolean == true
      else { return }
      renderer?.input(event: 1, point: self.point(event))
    }
    listen("pointerleave", on: host) { [weak renderer] _ in renderer?.input(event: 10) }
    for type in ["pointerup", "pointercancel"] {
      listen(type, on: document) { [weak self, weak renderer] event in
        guard let self, let pointer = self.trackingPointer,
          event.pointerId.number == Double(pointer)
        else { return }
        self.trackingPointer = nil
        if let id = self.pressedButton {
          self.pressedButton = nil
          renderer?.interact(id, .pressed(false))
        } else if type == "pointerup" {
          if self.host.contains!(event.target).boolean == true, let id = self.targetID(event) {
            renderer?.input(id: id, event: 3, point: self.point(event))
          } else {
            renderer?.endPointerOutside(at: self.point(event))
          }
        } else {
          renderer?.cancelPointer()
        }
      }
    }
    for (type, code) in [("dblclick", 4), ("contextmenu", 9)] {
      listen(type, on: host) { [weak self, weak renderer] event in
        guard let self else { return }
        if renderer?.input(id: self.targetID(event), event: code, point: self.point(event)) == true
        {
          _ = event.preventDefault!()
        }
      }
    }

    for (type, focused) in [("focusin", true), ("focusout", false)] {
      listen(type, on: host) { [weak self, weak renderer] event in
        guard let id = self?.targetID(event) else { return }
        if !focused, self?.composing == id { self?.composing = nil }
        renderer?.interact(id, .focus(focused))
      }
    }
    listen("compositionstart", on: host) { [weak self] event in
      self?.composing = self?.targetID(event)
    }
    for type in ["input", "compositionend"] {
      listen(type, on: host) { [weak self, weak renderer] event in
        guard let self, let id = self.targetID(event),
          let value = event.target.value.string
        else { return }
        if type == "compositionend" { self.composing = nil }
        guard self.composing != id else { return }
        renderer?.input(id: id, event: 7, text: value)
      }
    }
    listen("keydown", on: document) { [weak self, weak renderer] event in
      guard let self, event.isComposing.boolean != true, let key = event.key.string else { return }
      let keys = [
        "Backspace": 8, "Tab": 9, "Enter": 13, "Escape": 27, " ": 32, "PageUp": 33,
        "PageDown": 34, "End": 35, "Home": 36, "ArrowLeft": 37, "ArrowUp": 38,
        "ArrowRight": 39, "ArrowDown": 40, "Delete": 46,
      ]
      let scalar = key.unicodeScalars.count == 1 ? key.unicodeScalars.first : nil
      guard let value = keys[key] ?? scalar.map({ Int($0.value) }) else { return }
      var modifiers: EventModifiers = []
      if event.shiftKey.boolean == true { modifiers.insert(.shift) }
      if event.ctrlKey.boolean == true { modifiers.insert(.control) }
      if event.altKey.boolean == true { modifiers.insert(.option) }
      if event.metaKey.boolean == true { modifiers.insert(.command) }
      let id = self.host.contains!(event.target).boolean == true ? self.targetID(event) : nil
      if renderer?.input(id: id, event: 6, value: value, modifiers: modifiers) == true {
        _ = event.preventDefault!()
      }
    }

    listen("scroll", on: host, capture: true) { [weak self, weak renderer] event in
      guard let self, let id = self.targetID(event, selector: "[data-scroll][data-node]"),
        let dom = self.nodes[id]?.dom, dom == event.target.object
      else { return }
      renderer?.scroll(
        id: id,
        to: Point(x: dom.scrollLeft.number ?? 0, y: dom.scrollTop.number ?? 0))
    }
  }

  private func listen(
    _ type: String, on target: JSObject, capture: Bool = false, handle: @escaping (JSObject) -> Void
  ) {
    let listener = JSClosure { args in
      if let event = args.first?.object { handle(event) }
      return .undefined
    }
    listeners.append(listener)
    _ = target.addEventListener!(type, listener, capture)
  }

  private func point(_ event: JSObject) -> CGPoint {
    let bounds = host.getBoundingClientRect!().object!
    return CGPoint(
      x: (event.clientX.number ?? 0) - (bounds.left.number ?? 0),
      y: (event.clientY.number ?? 0) - (bounds.top.number ?? 0))
  }

  private func targetID(_ event: JSObject, selector: String = "[data-node]") -> NodeID? {
    guard let target = event.target.object,
      let closest: ((ConvertibleToJSValue...) -> JSValue) = target["closest"],
      let match = closest(selector).object,
      let value = match.getAttribute!("data-node").string, let id = Int(value)
    else { return nil }
    return NodeID(rawValue: id)
  }

  func didRender(_ root: Element) {
    var liveIDs: Set<NodeID> = []
    func collect(_ element: Element) {
      liveIDs.insert(element.id)
      element.children.forEach(collect)
    }
    collect(root)
    for id in nodes.keys where !liveIDs.contains(id) {
      if let node = nodes.removeValue(forKey: id) { _ = node.dom.remove!() }
    }
    var focus: JSObject?
    reconcile(root, parent: host, index: 0, origin: .zero, opacity: 1, focus: &focus)
    if let focus, document.activeElement.object != focus {
      let options: JSObject = ["preventScroll": .boolean(true)]
      _ = focus.focus!(options)
    }
  }

  private func reconcile(
    _ element: Element, parent: JSObject, index: Int, origin: Point, opacity: Double,
    focus: inout JSObject?
  ) {
    let id = element.id
    if element.kind == .textField, let old = nodes[id],
      old.props?.multiline != element.props.multiline
    {
      _ = old.dom.remove!()
      nodes.removeValue(forKey: id)
    }
    var node = nodes[id] ?? makeNode(element)
    let dom = node.dom
    let current = parent.children[index]
    if current.object != dom { _ = parent.insertBefore!(dom, current.object?.jsValue ?? .null) }

    let frame = Rect(
      x: element.frame.minX - origin.x, y: element.frame.minY - origin.y,
      width: element.frame.width, height: element.frame.height)
    let props = element.props
    let relativeOpacity = opacity > 0 ? props.opacity / opacity : 0
    let style = dom.style.object!
    if node.frame != frame {
      style.left = .string(px(frame.minX))
      style.top = .string(px(frame.minY))
      style.width = .string(px(max(0, frame.width)))
      style.height = .string(px(max(0, frame.height)))
    }
    if node.relativeOpacity != relativeOpacity { style.opacity = .string(String(relativeOpacity)) }
    if node.props != props || node.frame?.size != frame.size {
      updateStyle(node, for: element)
    }
    let acceptsPointer =
      props.hitTesting
      && (element.handlesPointerInput || element.needsNativeFocus || element.kind == .textField
        || element.kind == .scroll)
    if node.acceptsPointer != acceptsPointer {
      style.pointerEvents = .string(acceptsPointer ? "auto" : "none")
      node.acceptsPointer = acceptsPointer
    }
    if let clip = element.clipPathBuilder {
      let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
      let path = clip(rect).svgData
      if node.clipPath != path {
        style.clipPath = .string("path(\"\(path)\")")
        node.clipPath = path
      }
    } else if node.clipPath != nil {
      style.clipPath = .string("")
      node.clipPath = nil
    }
    if let drawing = node.drawing {
      let path = drawingPath(for: element)
      if node.drawingPath != path || node.props != props || node.frame?.size != frame.size {
        draw(element, path: path, in: drawing)
        node.drawingPath = path
      }
    }
    if element.kind == .textField, composing != id, dom.value.string != props.text {
      dom.value = .string(props.text)
    }
    if props.focusRequested && node.props?.focusRequested != true && props.enabled
      && props.visible && props.hitTesting
    {
      focus = dom
    }

    var childOrigin = element.frame.origin
    if element.kind == .scroll {
      // Layout frames already include the model offset. The browser applies
      // the offset itself, so mount children at their unscrolled positions.
      childOrigin.x -= props.scrollOffset.x
      childOrigin.y -= props.scrollOffset.y
      if let child = element.children.first, let contentStyle = node.content?.style.object {
        contentStyle.width = .string(px(child.frame.width))
        contentStyle.height = .string(px(child.frame.height))
      } else if let contentStyle = node.content?.style.object {
        contentStyle.width = .string("0px")
        contentStyle.height = .string("0px")
      }
    }
    var children =
      element.kind == .layer && props.layerBehind
      ? Array(element.children.reversed()) : element.children
    if children.contains(where: { $0.props.zIndex != 0 }) {
      children.sort { $0.props.zIndex < $1.props.zIndex }
    }
    for (childIndex, child) in children.enumerated() {
      reconcile(
        child, parent: node.content ?? dom, index: childIndex, origin: childOrigin,
        opacity: props.opacity, focus: &focus)
    }
    node.props = props
    node.frame = frame
    node.relativeOpacity = relativeOpacity
    nodes[id] = node
  }
}
