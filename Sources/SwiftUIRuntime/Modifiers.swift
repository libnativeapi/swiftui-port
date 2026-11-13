/// An individual edge and the set accepted by padding.

/// One chainable modifier application.

/// The view returned by a modifier. It renders its content and then folds the
/// modifier into the resulting element.
///
/// Padding and frames create wrapper elements to preserve modifier order.
/// Scalar properties are attached to the current node.

import Foundation

public enum Edge {
  case top, leading, bottom, trailing
  public struct Set: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let top = Set(rawValue: 1), leading = Set(rawValue: 2)
    public static let bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
    public static let horizontal: Set = [.leading, .trailing]
    public static let vertical: Set = [.top, .bottom]
    public static let all: Set = [.top, .leading, .bottom, .trailing]
  }
}
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
  func _makeElement(path: ViewPath) -> Element {
    let saved = EnvironmentValues.current
    if case .disabled(let disabled) = modifier {
      EnvironmentValues.current.isEnabled = !disabled
    }
    let renderPath: ViewPath
    if case .id(let value) = modifier {
      renderPath = path.appending(id: value)
    } else {
      renderPath = path
    }
    var element = _render(content, path: renderPath)
    EnvironmentValues.current = saved

    switch modifier {
    case .padding(let insets):
      var props = NodeProps()
      props.padding = insets
      element = Element(kind: .padding, props: props, children: [element])
    case .frame(let width, let height, let alignment):
      var props = NodeProps()
      props.frameWidth = width
      props.frameHeight = height
      props.alignment = alignment
      element = Element(kind: .frame, props: props, children: [element])
    case .background(let color):
      element.props.background = color
    case .foregroundColor(let color):
      element.props.foreground = color
    case .hidden:
      element.props.visible = false
    case .disabled(let disabled):
      element.props.disabledOverride = disabled
    case .onTapGesture(let action):
      // Windows routes both native button and host hit-test activation here.
      element.action = action
    case .id(let value):
      element.explicitID = value
    }

    return element
  }
}
extension View {
  /// Pads every edge by `value`.
  public func padding(_ value: Double) -> some View {
    padding(EdgeInsets.all(value))
  }

  /// Pads by explicit per-edge values.
  public func padding(_ insets: EdgeInsets) -> some View {
    ModifiedView(content: self, modifier: .padding(insets))
  }

  /// Pads only the selected edges.
  public func padding(_ edges: Edge.Set, _ value: Double) -> some View {
    var insets = EdgeInsets.zero
    if edges.contains(.top) { insets.top = value }
    if edges.contains(.leading) { insets.leading = value }
    if edges.contains(.bottom) { insets.bottom = value }
    if edges.contains(.trailing) { insets.trailing = value }
    return padding(insets)
  }

  /// Constrains the view's preferred size.
  ///
  /// Windows aligns the child inside an explicit frame wrapper. The Linux
  /// backend maps this to native preferred sizing. See docs/DIVERGENCES.md.
  public func frame(
    width: CGFloat? = nil,
    height: CGFloat? = nil,
    alignment: Alignment = .center
  ) -> some View {
    ModifiedView(
      content: self,
      modifier: .frame(
        width: width.map { Double($0) }, height: height.map { Double($0) }, alignment: alignment))
  }

  /// Draws `color` behind the view, including its padding if applied earlier.
  public func background(_ color: Color) -> some View {
    ModifiedView(content: self, modifier: .background(color))
  }

  /// Sets the text color for this view and its descendants.
  public func foregroundColor(_ color: Color) -> some View {
    ModifiedView(content: self, modifier: .foregroundColor(color))
  }

  /// Hides the view.
  ///
  /// nativeapi removes invisible views from stack layout, so unlike SwiftUI a
  /// hidden view does not reserve its space. See docs/DIVERGENCES.md.
  public func hidden() -> some View {
    ModifiedView(content: self, modifier: .hidden)
  }

  /// Disables this view and its descendants.
  public func disabled(_ disabled: Bool = true) -> some View {
    ModifiedView(content: self, modifier: .disabled(disabled))
  }

  /// Runs `action` when the view is tapped.
  ///
  /// Only buttons carry a click event in nativeapi v0.1, so this is effective
  /// on a `Button` (replacing its action) and inert elsewhere.
  public func onTapGesture(perform action: @escaping () -> Void) -> some View {
    ModifiedView(content: self, modifier: .onTapGesture(action))
  }

  /// Gives the view an explicit diff identity.
  ///
  /// Elements with the same id keep their native view when they move among
  /// siblings. v0.1 does not move a view across different parents.
  public func id<ID: Hashable>(_ id: ID) -> some View {
    ModifiedView(content: self, modifier: .id(AnyHashable(id)))
  }
}
extension View {
  public func frame(
    minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
    minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
    alignment: Alignment = .center
  ) -> some View {
    TransformView(content: self) { element in
      var props = NodeProps()
      props.minWidth = minWidth.map { Double($0) }
      props.minHeight = minHeight.map { Double($0) }
      props.idealWidth = idealWidth.map { Double($0) }
      props.idealHeight = idealHeight.map { Double($0) }
      props.maxWidth = maxWidth.map { Double($0) }
      props.maxHeight = maxHeight.map { Double($0) }
      props.fillWidth = maxWidth == .infinity
      props.fillHeight = maxHeight == .infinity
      props.alignment = alignment
      element = Element(kind: .frame, props: props, children: [element])
    }
  }
}
