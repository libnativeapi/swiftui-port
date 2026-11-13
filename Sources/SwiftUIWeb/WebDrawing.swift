import JavaScriptKit
import SwiftUIRuntime

extension WebBackend {
  func makeNode(_ element: Element) -> Node {
    let tag: String
    switch element.kind {
    case .button, .styledButton: tag = "button"
    case .textField: tag = element.props.multiline ? "textarea" : "input"
    default: tag = "div"
    }
    let dom = document.createElement!(tag).object!
    _ = dom.setAttribute!("data-node", String(element.id.rawValue))
    _ = dom.setAttribute!("data-kind", element.kind.description)
    if tag == "button" { dom.type = .string("button") }
    let style = dom.style.object!
    style.position = .string("absolute")
    style.boxSizing = .string("border-box")
    // Keep each sibling subtree in a single stacking context.
    style.isolation = .string("isolate")

    var drawing: JSObject?
    if element.kind == .shape || element.kind == .path || element.kind == .gradient {
      let svg = svgElement("svg")
      _ = svg.setAttribute!("aria-hidden", "true")
      let css = svg.style.object!
      css.position = .string("absolute")
      css.inset = .string("0")
      css.width = .string("100%")
      css.height = .string("100%")
      css.overflow = .string("visible")
      css.pointerEvents = .string("none")
      _ = dom.appendChild!(svg)
      drawing = svg
    }

    // Put layout children in their own DOM container when the node also
    // contains a drawing, or needs a browser-managed scrollable extent.
    var content: JSObject?
    if element.kind == .image {
      let image = document.createElement!("img").object!
      image.draggable = .boolean(false)
      image.style.display = .string("block")
      image.style.width = .string("100%")
      image.style.height = .string("100%")
      _ = dom.appendChild!(image)
      content = image
    } else if drawing != nil || element.kind == .scroll {
      let wrapper = document.createElement!("div").object!
      wrapper.style.position = .string("absolute")
      wrapper.style.inset = .string("0 auto auto 0")
      _ = dom.appendChild!(wrapper)
      content = wrapper
    }
    if element.kind == .scroll {
      _ = dom.setAttribute!("data-scroll", "")
    }
    return Node(dom: dom, drawing: drawing, content: content)
  }

  func updateStyle(_ node: Node, for element: Element) {
    let props = element.props
    let dom = node.dom
    let style = dom.style.object!
    let kind = element.kind
    let isButton = kind == .button || kind == .styledButton
    let isControl = isButton || kind == .textField
    let interactive = props.enabled && props.hitTesting && props.visible
    style.visibility = .string(props.visible ? "visible" : "hidden")
    dom.inert = .boolean(!props.hitTesting || !props.visible)
    style.transform = .string(
      props.rotation == 0 && props.scaleX == 1 && props.scaleY == 1
        ? "" : "rotate(\(props.rotation)deg) scale(\(props.scaleX), \(props.scaleY))")
    style.color = .string(props.foreground?.css ?? "")
    let radius = max(0, min(props.cornerRadius, min(element.frame.width, element.frame.height) / 2))
    style.borderRadius = .string(radius > 0 || props.clipped ? px(radius) : "")
    style.backgroundColor = .string(node.drawing == nil ? props.background?.css ?? "" : "")
    style.boxShadow = .string(
      props.shadows.map { shadow in
        "\(px(shadow.x)) \(px(shadow.y)) \(px(max(0, shadow.radius))) \(shadow.color.css)"
      }.joined(separator: ", "))
    style.overflow = .string(props.clipped ? "clip" : "")
    if props.borderWidth > 0, node.drawing == nil {
      // An inset shadow preserves the content box and the runtime's child coordinates.
      let border = "inset 0 0 0 \(px(props.borderWidth)) \(props.borderColor.css)"
      let shadows = style.boxShadow.string ?? ""
      style.boxShadow = .string(shadows.isEmpty ? border : "\(border), \(shadows)")
    }

    if isControl { dom.disabled = .boolean(!interactive) }
    if !isControl && element.needsNativeFocus {
      dom.tabIndex = .number(interactive ? 0 : -1)
    } else {
      _ = dom.removeAttribute!("tabindex")
    }
    if props.accessibilityHidden {
      _ = dom.setAttribute!("aria-hidden", "true")
    } else {
      _ = dom.removeAttribute!("aria-hidden")
    }
    let label =
      props.accessibilityLabel.isEmpty && kind == .textField
      ? props.placeholder : props.accessibilityLabel
    setAttribute("aria-label", label, on: dom)
    setAttribute("aria-description", props.accessibilityValue, on: dom)
    setAttribute("title", props.help, on: dom)

    if kind == .text || kind == .button || kind == .textField {
      let font = props.font ?? .body
      style.font = .string(font.css)
      style.lineHeight = .string(px(font.lineHeight + props.lineSpacing))
      style.letterSpacing = .string(px(props.tracking))
      style.textDecoration = .string(props.underline ? "underline" : "")
      style.textAlign = .string(
        props.textAlignment == .center
          ? "center"
          : props.textAlignment == .trailing ? "end" : kind == .button ? "center" : "start")
    }

    switch kind {
    case .text:
      let text = props.renderedText ?? props.text
      if dom.textContent.string != text { dom.textContent = .string(text) }
      style.whiteSpace = .string("pre")
    case .button:
      if dom.textContent.string != props.text { dom.textContent = .string(props.text) }
      style.padding = .string("0")
      style.whiteSpace = .string("pre")
    case .styledButton:
      style.padding = .string("0")
      style.border = .string("0")
      if props.background == nil { style.backgroundColor = .string("transparent") }
    case .textField:
      if !props.multiline { dom.type = .string(props.secure ? "password" : "text") }
      dom.placeholder = .string(props.placeholder)
      style.padding = .string(props.plainTextField ? "0" : "0 3px")
      style.border = .string(props.plainTextField ? "0" : "")
      if props.plainTextField && props.background == nil {
        style.backgroundColor = .string("transparent")
      }
      if props.plainTextField { style.caretColor = .string("currentColor") }
      style.resize = .string("none")
    case .image:
      if let image = node.content {
        image.alt = .string(props.accessibilityLabel)
        image.style.objectFit = .string(props.aspectFit ? "contain" : "fill")
        if props.imageTemplate {
          image.style.visibility = .string("hidden")
          _ = image.removeAttribute!("src")
          let encoded = JSObject.global.JSON.stringify(props.imagePath).string ?? "\"\""
          style.maskImage = .string("url(\(encoded))")
          style.maskSize = .string(props.aspectFit ? "contain" : "100% 100%")
          style.maskPosition = .string("center")
          style.maskRepeat = .string("no-repeat")
          style.backgroundColor = .string("currentColor")
          if !props.accessibilityHidden { _ = dom.setAttribute!("role", "img") }
        } else {
          style.maskImage = .string("")
          image.style.visibility = .string("")
          setAttribute("src", props.imagePath, on: image)
          _ = dom.removeAttribute!("role")
        }
      }
    case .scroll:
      style.overflowX = .string(props.scrollAxes.contains(.horizontal) ? "auto" : "hidden")
      style.overflowY = .string(props.scrollAxes.contains(.vertical) ? "auto" : "hidden")
      style.scrollbarWidth = .string(props.showsScrollIndicators ? "thin" : "none")
    default: break
    }
  }

  func drawingPath(for node: Element) -> String {
    let rect = CGRect(x: 0, y: 0, width: node.frame.width, height: node.frame.height)
    let path =
      node.pathBuilder?(rect)
      ?? (node.kind == .path
        ? node.props.path : Path(roundedRect: rect, cornerRadius: node.props.cornerRadius))
    return path.svgData
  }

  func draw(_ node: Element, path: String, in svg: JSObject) {
    let props = node.props
    let shape = svgElement("path")
    _ = shape.setAttribute!("d", path)
    _ = shape.setAttribute!("fill", (props.background ?? .clear).css)
    if props.borderWidth > 0 {
      _ = shape.setAttribute!("stroke", props.borderColor.css)
      _ = shape.setAttribute!("stroke-width", props.borderWidth)
      if !props.dash.isEmpty {
        _ = shape.setAttribute!(
          "stroke-dasharray", props.dash.map { String($0) }.joined(separator: " "))
      }
    }

    _ = svg.replaceChildren!(shape)
    if let gradient = props.gradient, !gradient.colors.isEmpty {
      if gradient.colors.count == 1 || gradient.start == gradient.end {
        _ = shape.setAttribute!("fill", gradient.colors.last!.css)
        return
      }
      let fill = svgElement("linearGradient")
      let id = "swiftui-gradient-\(node.id.rawValue)"
      _ = fill.setAttribute!("id", id)
      _ = fill.setAttribute!("gradientUnits", "userSpaceOnUse")
      _ = fill.setAttribute!("x1", gradient.start.x * node.frame.width)
      _ = fill.setAttribute!("y1", gradient.start.y * node.frame.height)
      _ = fill.setAttribute!("x2", gradient.end.x * node.frame.width)
      _ = fill.setAttribute!("y2", gradient.end.y * node.frame.height)
      for (index, color) in gradient.colors.enumerated() {
        let stop = svgElement("stop")
        _ = stop.setAttribute!("offset", Double(index) / Double(gradient.colors.count - 1))
        _ = stop.setAttribute!("stop-color", color.css)
        _ = fill.appendChild!(stop)
      }
      let definitions = svgElement("defs")
      _ = definitions.appendChild!(fill)
      _ = svg.insertBefore!(definitions, shape)
      _ = shape.setAttribute!("fill", "url(#\(id))")
    }
  }

  private func svgElement(_ name: String) -> JSObject {
    document.createElementNS!("http://www.w3.org/2000/svg", name).object!
  }

  private func setAttribute(_ name: String, _ value: String, on node: JSObject) {
    if value.isEmpty {
      _ = node.removeAttribute!(name)
    } else {
      _ = node.setAttribute!(name, value)
    }
  }
}

func px(_ value: Double) -> String { "\(value)px" }

extension Font {
  var css: String {
    let fallback = family == "Consolas" ? "monospace" : family == "Georgia" ? "serif" : "system-ui"
    let quoted = family.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\(weight.value) \(px(size)) \"\(quoted)\", \(fallback)"
  }

  var lineHeight: Double { ceil(size * 1.25) }
}

extension Color {
  fileprivate var css: String { "rgba(\(red * 255), \(green * 255), \(blue * 255), \(opacity))" }
}

extension Path {
  var svgData: String {
    var result = ""
    var index = 0
    while index < commands.count {
      let command: String
      let count: Int
      switch commands[index] {
      case 0: (command, count) = ("M", 2)
      case 1: (command, count) = ("L", 2)
      case 2: (command, count) = ("C", 6)
      case 3: (command, count) = ("Z", 0)
      default: return result
      }
      let end = index + 1 + count
      guard end <= commands.count else { break }
      result += command
      for coordinate in commands[(index + 1)..<end] { result += " \(coordinate)" }
      index = end
    }
    return result
  }
}
