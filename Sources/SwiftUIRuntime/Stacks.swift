/// A vertical stack: children top to bottom, separated by `spacing`.
public struct VStack<Content: View>: View {
  public typealias Body = Never

  public let alignment: HorizontalAlignment
  public let spacing: Double
  public let content: Content

  public init(
    alignment: HorizontalAlignment = .center,
    spacing: Double? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.alignment = alignment
    self.spacing = spacing ?? 8
    self.content = content()
  }

  public var body: Never { fatalError("VStack is a primitive view") }
}

extension VStack: _PrimitiveView {
  func _makeElement(path: ViewPath) -> Element {
    let contentElement = _render(content, path: path)
    var props = NodeProps()
    props.spacing = spacing
    props.horizontalAlignment = alignment
    return Element(
      kind: .container(.vertical),
      props: props,
      children: flattenChildren(contentElement)
    )
  }
}

/// A horizontal stack: children left to right, separated by `spacing`.
public struct HStack<Content: View>: View {
  public typealias Body = Never

  public let alignment: VerticalAlignment
  public let spacing: Double
  public let content: Content

  public init(
    alignment: VerticalAlignment = .center,
    spacing: Double? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.alignment = alignment
    self.spacing = spacing ?? 8
    self.content = content()
  }

  public var body: Never { fatalError("HStack is a primitive view") }
}

extension HStack: _PrimitiveView {
  func _makeElement(path: ViewPath) -> Element {
    let contentElement = _render(content, path: path)
    var props = NodeProps()
    props.spacing = spacing
    props.verticalAlignment = alignment
    return Element(
      kind: .container(.horizontal),
      props: props,
      children: flattenChildren(contentElement)
    )
  }
}
