import Foundation

public struct ViewDimensions {
  public let width: CGFloat, height: CGFloat
  public subscript(_ alignment: HorizontalAlignment) -> CGFloat {
    alignment == .leading ? 0 : alignment == .trailing ? width : width / 2
  }
  public subscript(_ alignment: VerticalAlignment) -> CGFloat {
    alignment == .top ? 0 : alignment == .bottom ? height : height / 2
  }
}
public enum LayoutDirection { case leftToRight, rightToLeft }
public enum ContentMode { case fit, fill }
public struct AnyTransition: Equatable {
  public var opacity: Double = 1, scale: Double = 1
  public static let opacity = AnyTransition(opacity: 0)
  public static let identity = AnyTransition()
  public static func scale(scale: Double = 0) -> Self { Self(scale: scale) }
  public func combined(with other: Self) -> Self {
    Self(opacity: opacity * other.opacity, scale: scale * other.scale)
  }
}
extension Font {
  public func weight(_ value: Weight) -> Font {
    var font = self
    font.weight = value
    return font
  }
}
struct FontTransform<Content: View>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let transform: (Font) -> Font
  var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    let old = EnvironmentValues.current
    EnvironmentValues.current.font = transform(old.font ?? .body)
    defer { EnvironmentValues.current = old }
    return _render(content, path: path)
  }
}
extension View {
  public func background<V: View>(_ background: V, alignment: Alignment = .center) -> some View {
    LayerView(content: self, layer: background, behind: true, alignment: alignment)
  }
  public func background<V: View>(alignment: Alignment, @ViewBuilder content: () -> V) -> some View
  { background(content(), alignment: alignment) }
  public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
    TransformView(content: self) {
      $0.props.offsetX += x
      $0.props.offsetY += y
    }
  }
  public func offset(_ offset: CGSize) -> some View {
    self.offset(x: offset.width, y: offset.height)
  }
  public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> some View {
    TransformView(content: self) {
      $0.props.scaleX *= scale
      $0.props.scaleY *= scale
    }
  }
  public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
    TransformView(content: self) { $0.props.rotation += angle.degrees }
  }
  public func zIndex(_ value: Double) -> some View {
    TransformView(content: self) { $0.props.zIndex = value }
  }
  public func allowsHitTesting(_ value: Bool) -> some View {
    TransformView(content: self) { $0.props.hitTesting = value }
  }
  public func fixedSize(horizontal: Bool = true, vertical: Bool = true) -> some View {
    TransformView(content: self) {
      $0.props.fixedWidth = horizontal
      $0.props.fixedHeight = vertical
    }
  }
  public func clipped(antialiased: Bool = false) -> some View { clipShape(Rectangle()) }
  public func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View {
    clipShape(RoundedRectangle(cornerRadius: radius))
  }
  public func border(_ color: Color, width: CGFloat = 1) -> some View {
    overlay(Rectangle().strokeBorder(color, lineWidth: width))
  }
  public func fontWeight(_ weight: Font.Weight?) -> some View {
    FontTransform(content: self) { $0.weight(weight ?? .regular) }
  }
  public func monospacedDigit() -> some View {
    FontTransform(content: self) {
      var font = $0
      font.family = "Consolas"
      return font
    }
  }
  public func underline(_ active: Bool = true, color: Color? = nil) -> some View {
    TransformView(content: self) { $0.props.underline = active }
  }
  public func scaledToFit() -> some View { aspectRatio(contentMode: .fit) }
  public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View {
    TransformView(content: self) {
      $0.props.aspectRatio = ratio.map { Double($0) }
      $0.props.aspectFit = contentMode == .fit
    }
  }
  public func alignmentGuide(
    _ guide: HorizontalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat
  ) -> some View { TransformView(content: self) { $0.horizontalGuide = computeValue } }
  public func alignmentGuide(
    _ guide: VerticalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat
  ) -> some View { TransformView(content: self) { $0.verticalGuide = computeValue } }
  public func coordinateSpace<Name: Hashable>(name: Name) -> some View {
    TransformView(content: self) { $0.props.coordinateSpace = AnyHashable(name) }
  }
  public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all)
    -> some View
  { self }  // desktop content has no safe-area insets
  public func transition(_ transition: AnyTransition) -> some View {
    TransformView(content: self) { $0.props.transition = transition }
  }
  public func padding() -> some View { padding(8) }
}
public struct SafeAreaRegions: OptionSet {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let all = Self(rawValue: 1)
}
extension Animation {
  public static func linear(duration: Double) -> Self { Self(duration: duration) }
  public static func easeInOut(duration: Double) -> Self { Self(duration: duration) }
  public static func easeOut(duration: Double) -> Self { Self(duration: duration) }
  public static func easeIn(duration: Double) -> Self { Self(duration: duration) }
  public static let `default` = Self(duration: 0.25)
  public func repeatForever(autoreverses: Bool = true) -> Self {
    var animation = self
    animation.repeats = true
    animation.autoreverses = autoreverses
    return animation
  }
  public func delay(_ value: Double) -> Self {
    var animation = self
    animation.delay = value
    return animation
  }
}
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () -> Result)
  -> Result
{
  let old = AnimationContext.current
  AnimationContext.current = animation
  defer { AnimationContext.current = old }
  return body()
}
enum AnimationContext { static var current: Animation? }
public enum TextAlignment: Equatable { case leading, center, trailing }
extension View {
  public func scaledToFill() -> some View { aspectRatio(contentMode: .fill) }
  public func tracking(_ spacing: CGFloat) -> some View {
    TransformView(content: self) { $0.props.tracking = spacing }
  }
  public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
    TransformView(content: self) { $0.props.textAlignment = alignment }
  }
  public func truncationMode(_ mode: Text.TruncationMode) -> some View {
    TransformView(content: self) { $0.props.truncationMode = mode }
  }
  public func tint(_ color: Color) -> some View { environment(\.tint, color) }
}
public struct StrokeStyle {
  public var lineWidth: CGFloat, dash: [CGFloat], dashPhase: CGFloat
  public init(lineWidth: CGFloat = 1, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
    self.lineWidth = lineWidth
    self.dash = dash
    self.dashPhase = dashPhase
  }
}
extension Shape {
  public func strokeBorder(_ color: Color, style: StrokeStyle) -> some View {
    TransformView(content: strokeBorder(color, lineWidth: style.lineWidth)) {
      $0.props.dash = style.dash.map { Double($0) }
    }
  }
  public func stroke(_ color: Color, style: StrokeStyle) -> some View {
    TransformView(content: stroke(color, lineWidth: style.lineWidth)) {
      $0.props.dash = style.dash.map { Double($0) }
    }
  }
}
