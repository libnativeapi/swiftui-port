/// The fake font metrics the engine uses.
///
/// nativeapi has no text measurement API exposed to Swift, and the native
/// backend delegates final sizing to each platform control. The engine only
/// needs deterministic numbers for its reference layout and its tests, so it
/// treats text as a fixed-width grid with a fixed line height.
public struct TextMetrics: Equatable {
  public var characterWidth: Double
  public var lineHeight: Double
  public var buttonHorizontalPadding: Double
  public var buttonVerticalPadding: Double

  public init(
    characterWidth: Double = 8,
    lineHeight: Double = 20,
    buttonHorizontalPadding: Double = 12,
    buttonVerticalPadding: Double = 6
  ) {
    self.characterWidth = characterWidth
    self.lineHeight = lineHeight
    self.buttonHorizontalPadding = buttonHorizontalPadding
    self.buttonVerticalPadding = buttonVerticalPadding
  }

  public static let `default` = TextMetrics()
}

/// Measures and places the element tree.
///
/// This is a reference layout: the engine uses it to report frames and to make
/// diffing and tests deterministic. At runtime `NativeViewBackend` hands the
/// stack structure to nativeapi, whose own layout pass produces the final
/// native frames. The two layouts follow the same Row/Column rules, but native
/// controls measure text with real font metrics.
public struct LayoutEngine {
  public var metrics: TextMetrics

  public init(metrics: TextMetrics = .default) {
    self.metrics = metrics
  }

  /// The size an element wants before its parent constrains it.
  public func measuredSize(of element: Element) -> Size {
    measure(element)
  }

  /// Lays out `root` in the given content size and writes a frame into every
  /// element.
  public func layout(root: inout Element, in size: Size) {
    let intrinsic = measure(root)
    let rootSize: Size
    switch root.kind {
    case .container, .padding, .fragment:
      rootSize = size
    default:
      rootSize = Size(
        width: min(intrinsic.width, size.width),
        height: min(intrinsic.height, size.height)
      )
    }
    place(&root, in: Rect(origin: .zero, size: rootSize))
  }

  // MARK: - Measurement

  private func measure(_ element: Element) -> Size {
    var size: Size
    switch element.kind {
    case .fragment:
      size = element.children.reduce(Size.zero) { partial, child in
        let childSize = measure(child)
        return Size(
          width: max(partial.width, childSize.width),
          height: max(partial.height, childSize.height)
        )
      }

    case .padding:
      let childSize = element.children.first.map(measure) ?? .zero
      size = Size(
        width: childSize.width + element.props.padding.horizontal,
        height: childSize.height + element.props.padding.vertical
      )

    case .container(let axis):
      let visible = element.children.filter(\.props.visible)
      let sizes = visible.map(measure)
      let totalMain = sizes.reduce(0.0) { partial, childSize in
        partial + (axis == .vertical ? childSize.height : childSize.width)
      }
      let maxCross = sizes.reduce(0.0) { partial, childSize in
        max(partial, axis == .vertical ? childSize.width : childSize.height)
      }
      let gaps = visible.count > 1 ? element.props.spacing * Double(visible.count - 1) : 0
      if axis == .vertical {
        size = Size(
          width: maxCross + element.props.padding.horizontal,
          height: totalMain + gaps + element.props.padding.vertical
        )
      } else {
        size = Size(
          width: totalMain + gaps + element.props.padding.horizontal,
          height: maxCross + element.props.padding.vertical
        )
      }

    case .text:
      size = Size(
        width: Double(element.props.text.count) * metrics.characterWidth,
        height: metrics.lineHeight
      )

    case .button:
      size = Size(
        width: Double(element.props.text.count) * metrics.characterWidth
          + metrics.buttonHorizontalPadding * 2,
        height: metrics.lineHeight + metrics.buttonVerticalPadding * 2
      )

    case .spacer, .empty:
      size = .zero
    }

    if let width = element.props.frameWidth {
      size.width = max(0, width)
    }
    if let height = element.props.frameHeight {
      size.height = max(0, height)
    }
    return size
  }

  // MARK: - Placement

  private func place(_ element: inout Element, in rect: Rect) {
    element.frame = rect

    switch element.kind {
    case .container(let axis):
      placeStackChildren(&element, axis: axis, in: rect)
    case .padding:
      if element.children.count == 1 {
        let inner = rect.inset(by: element.props.padding)
        let child = element.children[0]
        let natural = measure(child)
        // A container child fills the padded area; a leaf keeps its natural
        // size so text is not stretched by a root-level padding wrapper.
        let childSize = child.isContainer
          ? inner.size
          : Size(width: min(natural.width, inner.width), height: min(natural.height, inner.height))
        place(
          &element.children[0],
          in: Rect(origin: inner.origin, size: childSize)
        )
      } else {
        for index in element.children.indices {
          element.children[index].frame = .zero
        }
      }
    case .fragment:
      for index in element.children.indices {
        place(&element.children[index], in: rect)
      }
    case .text, .button, .spacer, .empty:
      break
    }
  }

  private func placeStackChildren(_ element: inout Element, axis: Axis, in rect: Rect) {
    let padding = element.props.padding
    let inner = rect.inset(by: padding)

    let visibleIndices = element.children.indices.filter { element.children[$0].props.visible }
    var fixedMain = 0.0
    var flexTotal = 0.0
    for index in visibleIndices {
      let child = element.children[index]
      let size = measure(child)
      if child.props.flex > 0 {
        flexTotal += child.props.flex
      } else {
        fixedMain += axis == .vertical ? size.height : size.width
      }
    }

    let mainExtent = axis == .vertical ? inner.height : inner.width
    let crossExtent = axis == .vertical ? inner.width : inner.height
    let gaps = visibleIndices.count > 1 ? element.props.spacing * Double(visibleIndices.count - 1) : 0
    let leftover = max(0, mainExtent - fixedMain - gaps)
    let mainStart = axis == .vertical ? inner.minY : inner.minX
    let crossStart = axis == .vertical ? inner.minX : inner.minY

    var cursor = mainStart
    var isFirst = true

    for index in element.children.indices {
      guard element.children[index].props.visible else {
        element.children[index].frame = .zero
        continue
      }
      if !isFirst {
        cursor += element.props.spacing
      }
      isFirst = false

      let child = element.children[index]
      let natural = measure(child)
      let mainSize: Double
      if child.props.flex > 0 {
        mainSize = flexTotal > 0 ? leftover * (child.props.flex / flexTotal) : 0
      } else {
        mainSize = axis == .vertical ? natural.height : natural.width
      }

      let naturalCross = axis == .vertical ? natural.width : natural.height
      let isFlexible = child.props.flex > 0
      let crossSize = isFlexible ? crossExtent : min(naturalCross, crossExtent)
      let crossOffsetStart: Double
      if isFlexible {
        crossOffsetStart = 0
      } else if axis == .vertical {
        switch element.props.horizontalAlignment {
        case .leading:
          crossOffsetStart = 0
        case .center:
          crossOffsetStart = (crossExtent - crossSize) / 2
        case .trailing:
          crossOffsetStart = crossExtent - crossSize
        }
      } else {
        switch element.props.verticalAlignment {
        case .top:
          crossOffsetStart = 0
        case .center:
          crossOffsetStart = (crossExtent - crossSize) / 2
        case .bottom:
          crossOffsetStart = crossExtent - crossSize
        }
      }

      let childRect = axis == .vertical
        ? Rect(x: crossStart + crossOffsetStart, y: cursor, width: crossSize, height: mainSize)
        : Rect(x: cursor, y: crossStart + crossOffsetStart, width: mainSize, height: crossSize)

      place(&element.children[index], in: childRect)
      cursor += mainSize
    }
  }
}
