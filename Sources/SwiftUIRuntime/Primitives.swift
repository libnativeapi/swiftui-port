/// A read-only piece of text.
///
/// `Text` maps to nativeapi's `Label`. It is single-line in v0.1: the engine's
/// fake metrics measure one line, and newlines are passed through to the
/// platform control rather than wrapped by the engine.
public struct Text: View {
  public typealias Body = Never

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
    return Element(kind: .text, props: props)
  }
}

/// A button with a title and an action.
///
/// The action runs on the UI thread from the native click event. A `@State`
/// write inside it schedules a new body evaluation.
public struct Button: View {
  public typealias Body = Never

  public let title: String
  public let action: () -> Void

  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: Never { fatalError("Button is a primitive view") }
}

extension Button: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    props.text = title
    return Element(kind: .button, props: props, action: action)
  }
}

/// Flexible space that takes a share of its stack's leftover main-axis room.
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

/// A view that renders nothing and occupies no space.
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

/// Flattens fragments and drops empty views from a container's content.
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
