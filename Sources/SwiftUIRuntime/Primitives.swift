/// Read-only text, with wrapping and explicit newlines on the Windows backend.

/// A native button whose action invalidates mounted state synchronously.

/// Flexible space in the enclosing stack.

/// A view that renders nothing and occupies no space.

/// Flattens fragments and drops empty children.

public struct Text: View {
  public typealias Body = Never

  public enum TruncationMode: Equatable { case head, middle, tail }
  struct Run {
    var text: String
    var font: Font?
    var color: Color?
  }
  var runs: [Run] = []
  var textFont: Font?, textColor: Color?
  public let content: String

  public init(_ content: String) {
    self.content = content
  }

  public var body: Never { fatalError("Text is a primitive view") }
}
extension Text: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    props.text = content
    props.font = textFont ?? EnvironmentValues.current.font
    props.foreground = textColor
    if !runs.isEmpty {
      let children = runs.map { run -> Element in
        var child = props
        child.text = run.text
        child.font = run.font ?? props.font
        child.foreground = run.color ?? props.foreground
        return Element(kind: .text, props: child)
      }
      var container = NodeProps()
      container.spacing = 0
      return Element(kind: .container(.horizontal), props: container, children: children)
    }
    return Element(kind: .text, props: props)
  }
}
public struct Button<Label: View>: View {
  public typealias Body = Never

  public let title: String
  public let action: () -> Void
  let label: Label

  public init(_ title: String, action: @escaping () -> Void) where Label == Text {
    self.title = title
    self.action = action
    self.label = Text(title)
  }

  public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
    self.title = ""
    self.action = action
    self.label = label()
  }
  public var body: Never { fatalError("Button is a primitive view") }
}
extension Button: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    // Unstyled buttons use the native title renderer. A custom ButtonStyle
    // renders the full label tree; the default style extracts its text.
    func text(_ element: Element) -> String {
      if element.kind == .text { return element.props.text }
      return element.children.map(text).filter { !$0.isEmpty }.joined(separator: " ")
    }
    props.text = title.isEmpty ? text(_render(label, path: path + [0])) : title
    return Element(kind: .button, props: props, action: action)
  }
}
public struct Spacer: View {
  public typealias Body = Never

  public let minLength: Double

  public init(minLength: Double? = nil) {
    self.minLength = minLength ?? 0
  }

  public var body: Never { fatalError("Spacer is a primitive view") }
}
extension Spacer: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    props.flex = 1
    return Element(kind: .spacer, props: props)
  }
}
public struct EmptyView: View {
  public typealias Body = Never

  public init() {}

  public var body: Never { fatalError("EmptyView is a primitive view") }
}
extension EmptyView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    Element(kind: .empty)
  }
}
func flattenChildren(_ element: Element) -> [Element] {
  switch element.kind {
  case .fragment:
    return element.children.flatMap(flattenChildren)
  case .empty:
    return []
  default:
    return [element]
  }
}
extension Text {
  public func font(_ font: Font?) -> Text {
    var text = self
    text.textFont = font
    return text
  }
  public func fontWeight(_ weight: Font.Weight?) -> Text {
    font((textFont ?? .body).weight(weight ?? .regular))
  }
  public func foregroundColor(_ color: Color) -> Text {
    var text = self
    text.textColor = color
    return text
  }
  public func foregroundColor(_ color: Color?) -> Text {
    var text = self
    text.textColor = color
    return text
  }
  public func foregroundStyle(_ color: Color) -> Text { foregroundColor(color) }
  public static func + (lhs: Text, rhs: Text) -> Text {
    var text = Text(lhs.content + rhs.content)
    text.runs =
      (lhs.runs.isEmpty
        ? [Run(text: lhs.content, font: lhs.textFont, color: lhs.textColor)] : lhs.runs)
      + (rhs.runs.isEmpty
        ? [Run(text: rhs.content, font: rhs.textFont, color: rhs.textColor)] : rhs.runs)
    return text
  }
}
