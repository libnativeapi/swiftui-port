@_exported import Foundation

/// Timing for the supported Windows drawing-property animations.

public struct Font: Equatable, Sendable {
  public struct Weight: Equatable, Sendable {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public static let ultraLight = Weight(100), thin = Weight(200), light = Weight(300)
    public static let regular = Weight(400), medium = Weight(500), semibold = Weight(600)
    public static let bold = Weight(700), heavy = Weight(800), black = Weight(900)
  }
  public enum Design: Sendable { case `default`, monospaced, rounded, serif }
  public var size: CGFloat
  public var weight: Weight
  public var family: String
  public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default)
    -> Font
  {
    Font(
      size: size, weight: weight,
      family: design == .monospaced ? "Consolas" : design == .serif ? "Georgia" : "Segoe UI")
  }
  public static func custom(_ name: String, size: CGFloat) -> Font {
    Font(size: size, weight: .regular, family: name)
  }
  public static let body = Font.system(size: 14)
}
public struct Animation: Equatable, Sendable {
  public let duration: Double
  public var repeats = false, autoreverses = false
  public var delay: Double = 0
  public static func timingCurve(
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, duration: Double
  ) -> Animation {
    Animation(duration: duration)
  }
}
@MainActor @preconcurrency public protocol ViewModifier {
  associatedtype Body: View
  typealias Content = AnyView
  @ViewBuilder func body(content: Content) -> Body
}
struct ModifierContent<Content: View, Modifier: ViewModifier>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let modifier: Modifier
  var body: Never { fatalError("ModifierContent is primitive") }
  func _makeElement(path: [Int]) -> Element {
    _installState(modifier, path: path)
    return _render(modifier.body(content: AnyView(content)), path: path)
  }
}
public struct Group<Content: View>: View {
  let content: Content
  public init(@ViewBuilder content: () -> Content) { self.content = content() }
  public var body: some View { content }
}
extension Optional: View where Wrapped: View {
  public var body: some View { if let value = self { value } }
}
public enum RoundedCornerStyle { case circular, continuous }
public protocol Shape: View {
  var cornerRadius: CGFloat { get }
  func path(in rect: CGRect) -> Path
}
public struct Rectangle: Shape {
  public init() {}
  public var cornerRadius: CGFloat { 0 }
  public var body: some View { ShapeView(radius: 0, fill: .black) }
}
public struct RoundedRectangle: Shape {
  public let cornerRadius: CGFloat
  public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
    self.cornerRadius = cornerRadius
  }
  public var body: some View { ShapeView(radius: cornerRadius, fill: .black) }
}
extension Shape {
  public func fill(_ color: Color) -> some View {
    PaintedShape(shape: self, fill: color, stroke: .clear, width: 0, inset: false)
  }
  public func strokeBorder(_ color: Color, lineWidth: CGFloat = 1) -> some View {
    PaintedShape(shape: self, fill: .clear, stroke: color, width: lineWidth, inset: true)
  }
}
struct ShapeView: View, _PrimitiveView {
  typealias Body = Never
  let radius: CGFloat
  let fill: Color
  var stroke: Color = .clear
  var lineWidth: CGFloat = 0
  var body: Never { fatalError("Shape is primitive") }
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    props.background = fill
    props.cornerRadius = Double(radius)
    props.borderColor = stroke
    props.borderWidth = Double(lineWidth)
    props.fillWidth = true
    props.fillHeight = true
    return Element(kind: .shape, props: props)
  }
}
struct TransformView<Content: View>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let transform: (inout Element) -> Void
  var body: Never { fatalError("TransformView is primitive") }
  func _makeElement(path: [Int]) -> Element {
    var result = _render(content, path: path)
    transform(&result)
    return result
  }
}
struct LayerView<Content: View, Layer: View>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let layer: Layer
  let behind: Bool
  let alignment: Alignment
  var body: Never { fatalError("LayerView is primitive") }
  func _makeElement(path: [Int]) -> Element {
    var props = NodeProps()
    props.alignment = alignment
    props.layerBehind = behind
    return Element(
      kind: .layer, props: props,
      children: [
        _render(content, path: path + [0]), _render(layer, path: path + [1]),
      ])
  }
}
public struct Shadow: Equatable {
  public var color: Color
  public var radius: Double
  public var x: Double
  public var y: Double
}
extension View {
  public func modifier<M: ViewModifier>(_ modifier: M) -> some View {
    ModifierContent(content: self, modifier: modifier)
  }
  public func font(_ font: Font?) -> some View { environment(\.font, font) }
  public func foregroundStyle(_ color: Color) -> some View { foregroundColor(color) }
  public func lineLimit(_ limit: Int?) -> some View {
    TransformView(content: self) { $0.props.lineLimit = limit }
  }
  public func lineSpacing(_ spacing: CGFloat) -> some View {
    TransformView(content: self) { $0.props.lineSpacing = Double(spacing) }
  }
  public func opacity(_ value: Double) -> some View {
    TransformView(content: self) { $0.props.opacity *= value }
  }
  public func clipShape<S: Shape>(_ shape: S) -> some View {
    TransformView(content: self) {
      $0.props.cornerRadius = Double(shape.cornerRadius)
      $0.props.clipped = true
      $0.clipPathBuilder = { shape.path(in: $0) }
    }
  }
  public func contentShape<S: Shape>(_ shape: S) -> some View {
    TransformView(content: self) { $0.props.hitRadius = Double(shape.cornerRadius) }
  }
  public func background<V: View>(@ViewBuilder content: () -> V) -> some View {
    LayerView(content: self, layer: content(), behind: true, alignment: .center)
  }
  public func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> some View {
    LayerView(content: self, layer: overlay, behind: false, alignment: alignment)
  }
  public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V)
    -> some View
  { overlay(content(), alignment: alignment) }
  public func shadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
    TransformView(content: self) {
      $0.props.shadows.append(
        Shadow(color: color, radius: Double(radius), x: Double(x), y: Double(y)))
    }
  }
  public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
    TransformView(content: self) { $0.props.animation = animation }
  }
  public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
    TransformView(content: self) { $0.hoverAction = action }
  }
  public func help(_ text: String) -> some View {
    TransformView(content: self) { $0.props.help = text }
  }
  public func focused(_ binding: FocusState<Bool>.Binding) -> some View {
    TransformView(content: self) {
      $0.focusAction = binding.set
      $0.props.focusRequested = binding.get()
    }
  }
}
@propertyWrapper public struct FocusState<Value: Hashable>: _StateProperty {
  public struct Binding {
    let get: () -> Value
    let set: (Value) -> Void
  }
  private var state: State<Value>
  public init() where Value == Bool { state = State(wrappedValue: false) }
  public init<T>() where Value == T? { state = State(wrappedValue: nil) }
  public var wrappedValue: Value {
    get { state.wrappedValue }
    nonmutating set { if state.wrappedValue != newValue { state.wrappedValue = newValue } }
  }
  public var projectedValue: Binding { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
  func install(_ key: StateKey) { state.install(key) }
}
