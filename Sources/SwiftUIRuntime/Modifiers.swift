/// A set of edges for the `padding(_:_:)` modifier.
///
/// SwiftUI spells this `Edge.Set`; this port uses a standalone `Edge` option
/// set because the exact nested spelling is not part of the v0.1 symbol list.
public struct Edge: OptionSet, Hashable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let top = Edge(rawValue: 1 << 0)
  public static let leading = Edge(rawValue: 1 << 1)
  public static let bottom = Edge(rawValue: 1 << 2)
  public static let trailing = Edge(rawValue: 1 << 3)

  public static let horizontal: Edge = [.leading, .trailing]
  public static let vertical: Edge = [.top, .bottom]
  public static let all: Edge = [.top, .leading, .bottom, .trailing]
}

/// One chainable modifier application.
enum ViewModifierValue {
  case padding(EdgeInsets)
  case frame(width: Double?, height: Double?, alignment: Alignment)
  case background(Color)
  case foregroundColor(Color)
  case hidden
  case disabled(Bool)
  case onTapGesture(() -> Void)
  case id(AnyHashable)
}

/// The view returned by a modifier. It renders its content and then folds the
/// modifier into the resulting element.
///
/// `.padding` is the one modifier that creates a new wrapper element, because
/// nativeapi has no per-control padding. Everything else updates the element's
/// properties. This means modifier order is preserved for padding versus
/// background/frame, while other combinations (for example
/// `.hidden().padding()`) collapse into the same element.
public struct ModifiedView<Content: View>: View {
  public typealias Body = Never

  let content: Content
  let modifier: ViewModifierValue

  init(content: Content, modifier: ViewModifierValue) {
    self.content = content
    self.modifier = modifier
  }

  public var body: Never { fatalError("ModifiedView is a primitive view") }
}

extension ModifiedView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    var element = _render(content, path: path)

    switch modifier {
    case .padding(let insets):
      var props = NodeProps()
      props.padding = insets
      element = Element(kind: .padding, props: props, children: [element])
    case .frame(let width, let height, _):
      element.props.frameWidth = width
      element.props.frameHeight = height
    case .background(let color):
      element.props.background = color
    case .foregroundColor(let color):
      element.props.foreground = color
    case .hidden:
      element.props.visible = false
    case .disabled(let disabled):
      element.props.disabledOverride = disabled
    case .onTapGesture(let action):
      // nativeapi only exposes a click event on Button. Attaching a tap
      // gesture to a Button replaces its action; on other views it is kept
      // for diagnostics but cannot fire. See docs/DIVERGENCES.md.
      element.action = action
    case .id(let value):
      element.explicitID = value
    }

    return element
  }
}

public extension View {
  /// Pads every edge by `value`.
  func padding(_ value: Double) -> some View {
    padding(EdgeInsets.all(value))
  }

  /// Pads by explicit per-edge values.
  func padding(_ insets: EdgeInsets) -> some View {
    ModifiedView(content: self, modifier: .padding(insets))
  }

  /// Pads only the selected edges.
  func padding(_ edges: Edge, _ value: Double) -> some View {
    var insets = EdgeInsets.zero
    if edges.contains(.top) { insets.top = value }
    if edges.contains(.leading) { insets.leading = value }
    if edges.contains(.bottom) { insets.bottom = value }
    if edges.contains(.trailing) { insets.trailing = value }
    return padding(insets)
  }

  /// Constrains the view's preferred size.
  ///
  /// There is no per-view alignment layout in nativeapi; `alignment` is
  /// accepted for source compatibility and currently only affects the frame
  /// metadata. See docs/DIVERGENCES.md.
  func frame(
    width: Double? = nil,
    height: Double? = nil,
    alignment: Alignment = .center
  ) -> some View {
    ModifiedView(content: self, modifier: .frame(width: width, height: height, alignment: alignment))
  }

  /// Draws `color` behind the view, including its padding if applied earlier.
  func background(_ color: Color) -> some View {
    ModifiedView(content: self, modifier: .background(color))
  }

  /// Sets the text color for this view and its descendants.
  func foregroundColor(_ color: Color) -> some View {
    ModifiedView(content: self, modifier: .foregroundColor(color))
  }

  /// Hides the view.
  ///
  /// nativeapi removes invisible views from stack layout, so unlike SwiftUI a
  /// hidden view does not reserve its space. See docs/DIVERGENCES.md.
  func hidden() -> some View {
    ModifiedView(content: self, modifier: .hidden)
  }

  /// Disables this view and its descendants.
  func disabled(_ disabled: Bool = true) -> some View {
    ModifiedView(content: self, modifier: .disabled(disabled))
  }

  /// Runs `action` when the view is tapped.
  ///
  /// Only buttons carry a click event in nativeapi v0.1, so this is effective
  /// on a `Button` (replacing its action) and inert elsewhere.
  func onTapGesture(perform action: @escaping () -> Void) -> some View {
    ModifiedView(content: self, modifier: .onTapGesture(action))
  }

  /// Gives the view an explicit diff identity.
  ///
  /// Elements with the same id keep their native view when they move among
  /// siblings. v0.1 does not move a view across different parents.
  func id<ID: Hashable>(_ id: ID) -> some View {
    ModifiedView(content: self, modifier: .id(AnyHashable(id)))
  }
}
