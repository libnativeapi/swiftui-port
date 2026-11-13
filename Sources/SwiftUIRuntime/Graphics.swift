import Foundation

/// Backend-neutral vector path. Each command is M(x,y), L(x,y), C(6), or Z.

public struct Angle: Equatable {
  public var radians: Double
  public var degrees: Double { radians * 180 / .pi }
  public static func degrees(_ value: Double) -> Angle { Angle(radians: value * .pi / 180) }
  public static func radians(_ value: Double) -> Angle { Angle(radians: value) }
}
public struct Path: Equatable {
  public var commands: [Double] = []
  public init() {}
  public init(_ build: (inout Path) -> Void) {
    self.init()
    build(&self)
  }
  public init(_ other: Path) { self = other }
  public var cgPath: Path { self }
  public init(_ rect: CGRect) {
    self.init()
    addRect(rect)
  }
  public init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
    self.init()
    let r = min(cornerRadius, rect.width / 2, rect.height / 2)
    move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    addArc(
      center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90),
      endAngle: .degrees(0), clockwise: false)
    addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    addArc(
      center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0),
      endAngle: .degrees(90), clockwise: false)
    addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    addArc(
      center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90),
      endAngle: .degrees(180), clockwise: false)
    addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    addArc(
      center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180),
      endAngle: .degrees(270), clockwise: false)
    closeSubpath()
  }
  public mutating func move(to p: CGPoint) { commands += [0, p.x, p.y] }
  public mutating func addLine(to p: CGPoint) { commands += [1, p.x, p.y] }
  public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) {
    commands += [2, control1.x, control1.y, control2.x, control2.y, p.x, p.y]
  }
  public mutating func closeSubpath() { commands.append(3) }
  public mutating func addRect(_ r: CGRect) {
    move(to: r.origin)
    addLine(to: CGPoint(x: r.maxX, y: r.minY))
    addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    addLine(to: CGPoint(x: r.minX, y: r.maxY))
    closeSubpath()
  }
  public mutating func addPath(_ path: Path) { commands += path.commands }
  public mutating func addArc(
    center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool
  ) {
    var delta = endAngle.radians - startAngle.radians
    if clockwise && delta > 0 { delta -= 2 * .pi }
    if !clockwise && delta < 0 { delta += 2 * .pi }
    let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / Double(pieces)
    let start = CGPoint(
      x: center.x + radius * cos(startAngle.radians), y: center.y + radius * sin(startAngle.radians)
    )
    if commands.isEmpty { move(to: start) } else { addLine(to: start) }
    for i in 0..<pieces {
      let a = startAngle.radians + Double(i) * step
      let b = a + step
      let k = 4 / 3 * tan(step / 4)
      addCurve(
        to: CGPoint(x: center.x + radius * cos(b), y: center.y + radius * sin(b)),
        control1: CGPoint(
          x: center.x + radius * (cos(a) - k * sin(a)), y: center.y + radius * (sin(a) + k * cos(a))
        ),
        control2: CGPoint(
          x: center.x + radius * (cos(b) + k * sin(b)), y: center.y + radius * (sin(b) - k * cos(b))
        ))
    }
  }
  public func transformed(x: Double = 0, y: Double = 0, sx: Double = 1, sy: Double = 1) -> Path {
    var output = self
    var i = 0
    while i < commands.count {
      let n = commands[i] == 2 ? 6 : commands[i] == 3 ? 0 : 2
      for j in stride(from: 1, through: n, by: 2) {
        output.commands[i + j] = commands[i + j] * sx + x
        output.commands[i + j + 1] = commands[i + j + 1] * sy + y
      }
      i += n + 1
    }
    return output
  }
}
public struct Circle: Shape {
  public init() {}
  public func path(in r: CGRect) -> Path {
    var p = Path()
    p.addArc(
      center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
      startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
    p.closeSubpath()
    return p
  }
}
public struct Capsule: Shape {
  public init(style: RoundedCornerStyle = .continuous) {}
  public var cornerRadius: CGFloat { .infinity }
}
public struct RectangleCornerRadii {
  public var topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat,
    topTrailing: CGFloat
  public init(
    topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0,
    topTrailing: CGFloat = 0
  ) {
    self.topLeading = topLeading
    self.bottomLeading = bottomLeading
    self.bottomTrailing = bottomTrailing
    self.topTrailing = topTrailing
  }
}
public struct UnevenRoundedRectangle: Shape {
  let radii: RectangleCornerRadii
  public init(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
    radii = cornerRadii
  }
  public func path(in r: CGRect) -> Path {
    var p = Path()
    let tl = min(radii.topLeading, r.width / 2, r.height / 2)
    let tr = min(radii.topTrailing, r.width / 2, r.height / 2)
    let br = min(radii.bottomTrailing, r.width / 2, r.height / 2)
    let bl = min(radii.bottomLeading, r.width / 2, r.height / 2)
    p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
    p.addArc(
      center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90),
      endAngle: .degrees(0), clockwise: false)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
    p.addArc(
      center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0),
      endAngle: .degrees(90), clockwise: false)
    p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
    p.addArc(
      center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90),
      endAngle: .degrees(180), clockwise: false)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
    p.addArc(
      center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180),
      endAngle: .degrees(270), clockwise: false)
    p.closeSubpath()
    return p
  }
}
struct PaintedShape<S: Shape>: View, _PrimitiveView {
  typealias Body = Never
  let shape: S
  let fill: Color
  let stroke: Color
  let width: CGFloat
  let inset: Bool
  var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    var p = NodeProps()
    p.fillWidth = true
    p.fillHeight = true
    p.background = fill
    p.cornerRadius = Double(shape.cornerRadius)
    p.borderColor = stroke
    p.borderWidth = width
    var e = Element(kind: .shape, props: p)
    e.pathBuilder = { r in shape.path(in: inset ? r.insetBy(dx: width / 2, dy: width / 2) : r) }
    return e
  }
}
public struct TrimmedShape<S: Shape>: Shape {
  let shape: S
  let from: CGFloat
  let to: CGFloat
  let inset: CGFloat
  public func path(in r: CGRect) -> Path {
    // Circular paths preserve a true arc rather than closing the trimmed span.
    if shape is Circle {
      var p = Path()
      p.addArc(
        center: CGPoint(x: r.midX, y: r.midY), radius: max(0, min(r.width, r.height) / 2 - inset),
        startAngle: .degrees(from * 360), endAngle: .degrees(to * 360), clockwise: false)
      return p
    }
    return shape.path(in: r.insetBy(dx: inset, dy: inset))
  }
}
extension Shape {
  public var cornerRadius: CGFloat { 0 }
  public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: cornerRadius) }
  public var body: some View { fill(.black) }
  public func trim(from: CGFloat = 0, to: CGFloat = 1) -> some Shape {
    TrimmedShape(shape: self, from: from, to: to, inset: 0)
  }
  public func inset(by amount: CGFloat) -> some Shape { InsetShape(shape: self, amount: amount) }
  public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> some View {
    PaintedShape(shape: self, fill: .clear, stroke: color, width: lineWidth, inset: false)
  }
}
public struct InsetShape<S: Shape>: Shape {
  let shape: S
  let amount: CGFloat
  public func path(in rect: CGRect) -> Path { shape.path(in: rect.insetBy(dx: amount, dy: amount)) }
  public func trim(from: CGFloat = 0, to: CGFloat = 1) -> some Shape {
    TrimmedShape(shape: shape, from: from, to: to, inset: amount)
  }
}
public struct LinearGradient: View, _PrimitiveView {
  public typealias Body = Never
  public struct Data: Equatable {
    public let colors: [Color]
    public let start: UnitPoint
    public let end: UnitPoint
  }
  let data: Data
  public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
    data = Data(colors: colors, start: startPoint, end: endPoint)
  }
  public var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    var p = NodeProps()
    p.gradient = data
    p.fillWidth = true
    p.fillHeight = true
    return Element(kind: .gradient, props: p)
  }
}
public struct Image: View, _PrimitiveView {
  public typealias Body = Never
  public enum TemplateRenderingMode { case template, original }
  let name: String
  let bundle: Bundle
  var template = false
  var flexible = false
  public init(_ name: String, bundle: Bundle? = nil) {
    self.name = name
    self.bundle = bundle ?? .main
  }
  public var body: Never { fatalError() }
  public func resizable() -> Image {
    var image = self
    image.flexible = true
    return image
  }
  public func renderingMode(_ mode: TemplateRenderingMode?) -> Image {
    var image = self
    image.template = mode == .template
    return image
  }
  func _makeElement(path: [Int]) -> Element {
    var p = NodeProps()
    p.imagePath =
      bundle.url(forResource: name, withExtension: "svg")?.path ?? bundle.url(
        forResource: name, withExtension: "png")?.path ?? name
    p.imageTemplate = template
    p.fillWidth = flexible
    p.fillHeight = flexible
    return Element(kind: .image, props: p)
  }
}
public struct GraphicsContext {
  public enum Shading { case color(Color) }
  var elements: [Element] = []
  var tx: Double = 0, ty: Double = 0, sx: Double = 1, sy: Double = 1
  public mutating func translateBy(x: CGFloat, y: CGFloat) {
    tx += x * sx
    ty += y * sy
  }
  public mutating func scaleBy(x: CGFloat, y: CGFloat) {
    sx *= x
    sy *= y
  }
  public mutating func fill(_ path: Path, with shading: Shading) {
    var p = NodeProps()
    p.path = path.transformed(x: tx, y: ty, sx: sx, sy: sy)
    if case .color(let c) = shading { p.background = c }
    p.fillWidth = true
    p.fillHeight = true
    elements.append(Element(kind: .path, props: p))
  }
  public mutating func clip(to path: Path) { clipPath = path }
  var clipPath: Path?
}
public struct Canvas: View, _PrimitiveView {
  public typealias Body = Never
  let renderer: (inout GraphicsContext, CGSize) -> Void
  public init(renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
    self.renderer = renderer
  }
  public var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    var p = NodeProps()
    p.fillWidth = true
    p.fillHeight = true
    var e = Element(kind: .geometry, props: p)
    e.geometryBuilder = { rect in
      var context = GraphicsContext()
      renderer(&context, rect.size)
      var result = Element(kind: .zStack, children: context.elements)
      if let clip = context.clipPath { result.clipPathBuilder = { _ in clip } }
      return result
    }
    return e
  }
}
