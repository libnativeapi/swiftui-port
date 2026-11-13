import Foundation

/// SVG path geometry for bundled template images. Parsing is cached by URL.
/// Supports the SVG path grammar, including elliptical arcs and smooth curves.
import SwiftUIRuntime

struct VectorImage {
  let bounds: CGRect
  let paths: [Path]
  static var cache: [String: VectorImage] = [:]

  static func load(_ file: String) -> VectorImage? {
    if let cached = cache[file] { return cached }
    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    func attributes(_ name: String) -> [String] {
      let pattern = name + "=[\"']([^\"']*)[\"']"
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
      return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap
      { match in
        Range(match.range(at: 1), in: source).map { String(source[$0]) }
      }
    }
    let box =
      attributes("viewBox").first?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap {
        Double($0)
      } ?? []
    guard box.count == 4, box[2] > 0, box[3] > 0 else { return nil }
    let image = VectorImage(
      bounds: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
      paths: attributes("(?:^|\\s)d").map { parse($0) })
    cache[file] = image
    return image
  }

  private static func parse(_ source: String) -> Path {
    let regex = try! NSRegularExpression(
      pattern: "[a-zA-Z]|[-+]?(?:[0-9]*[.])?[0-9]+(?:[eE][-+]?[0-9]+)?")
    let tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
      String(source[Range($0.range, in: source)!])
    }
    var i = 0
    var command = "M"
    var previous = ""
    var point = CGPoint.zero
    var start = CGPoint.zero
    var control = CGPoint.zero
    var path = Path()
    func number() -> Double {
      defer { i += 1 }
      return Double(tokens[i]) ?? 0
    }
    func isCommand(_ token: String) -> Bool { token.count == 1 && token.first!.isLetter }
    while i < tokens.count {
      if isCommand(tokens[i]) {
        command = tokens[i]
        i += 1
      }
      let upper = command.uppercased()
      let relative = command != upper
      let count: Int
      switch upper {
      case "Z": count = 0
      case "H", "V": count = 1
      case "M", "L", "T": count = 2
      case "S", "Q": count = 4
      case "C": count = 6
      case "A": count = 7
      default: return path
      }
      if count > 0 && (i + count > tokens.count || tokens[i..<i + count].contains(where: isCommand))
      {
        return path
      }
      let base = relative ? point : .zero
      func pair() -> CGPoint {
        let x = number()
        let y = number()
        return CGPoint(x: x + base.x, y: y + base.y)
      }
      switch upper {
      case "M":
        point = pair()
        start = point
        path.move(to: point)
        command = relative ? "l" : "L"
      case "L":
        point = pair()
        path.addLine(to: point)
      case "H":
        point.x = number() + base.x
        path.addLine(to: point)
      case "V":
        point.y = number() + base.y
        path.addLine(to: point)
      case "C":
        let c1 = pair()
        let c2 = pair()
        let end = pair()
        path.addCurve(to: end, control1: c1, control2: c2)
        control = c2
        point = end
      case "S":
        let c1 =
          (previous == "C" || previous == "S")
          ? CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y) : point
        let c2 = pair()
        let end = pair()
        path.addCurve(to: end, control1: c1, control2: c2)
        control = c2
        point = end
      case "Q", "T":
        let c: CGPoint
        if upper == "Q" {
          c = pair()
        } else {
          c =
            (previous == "Q" || previous == "T")
            ? CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y) : point
        }
        let end = pair()
        path.addCurve(
          to: end,
          control1: CGPoint(
            x: point.x + (c.x - point.x) * 2 / 3, y: point.y + (c.y - point.y) * 2 / 3),
          control2: CGPoint(x: end.x + (c.x - end.x) * 2 / 3, y: end.y + (c.y - end.y) * 2 / 3))
        control = c
        point = end
      case "A":
        let rx = number()
        let ry = number()
        let rotation = number()
        let large = number() != 0
        let sweep = number() != 0
        let end = pair()
        arc(
          &path, from: point, to: end, rx: rx, ry: ry, rotation: rotation, large: large,
          sweep: sweep)
        point = end
      case "Z":
        path.closeSubpath()
        point = start
        command = "M"
      default: break
      }
      previous = upper
    }
    return path
  }
  private static func arc(
    _ path: inout Path, from p: CGPoint, to q: CGPoint, rx rX: Double, ry rY: Double,
    rotation: Double, large: Bool, sweep: Bool
  ) {
    var rx = abs(rX)
    var ry = abs(rY)
    if rx == 0 || ry == 0 {
      path.addLine(to: q)
      return
    }
    if p == q { return }
    let phi = rotation * .pi / 180
    let c = cos(phi)
    let s = sin(phi)
    let dx = (p.x - q.x) / 2
    let dy = (p.y - q.y) / 2
    let x = c * dx + s * dy
    let y = -s * dx + c * dy
    let lambda = x * x / (rx * rx) + y * y / (ry * ry)
    if lambda > 1 {
      rx *= sqrt(lambda)
      ry *= sqrt(lambda)
    }
    let numerator = max(0, rx * rx * ry * ry - rx * rx * y * y - ry * ry * x * x)
    let denominator = rx * rx * y * y + ry * ry * x * x
    let factor = (large == sweep ? -1.0 : 1.0) * sqrt(numerator / max(denominator, 1e-20))
    let cxp = factor * rx * y / ry
    let cyp = -factor * ry * x / rx
    let cx = c * cxp - s * cyp + (p.x + q.x) / 2
    let cy = s * cxp + c * cyp + (p.y + q.y) / 2
    let a = atan2((y - cyp) / ry, (x - cxp) / rx)
    let end = atan2((-y - cyp) / ry, (-x - cxp) / rx)
    var delta = end - a
    if sweep && delta < 0 { delta += 2 * .pi }
    if !sweep && delta > 0 { delta -= 2 * .pi }
    let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / Double(pieces)
    func transform(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(x: cx + c * rx * x - s * ry * y, y: cy + s * rx * x + c * ry * y)
    }
    for i in 0..<pieces {
      let a = a + Double(i) * step
      let b = a + step
      let k = 4 / 3 * tan(step / 4)
      path.addCurve(
        to: transform(cos(b), sin(b)),
        control1: transform(cos(a) - k * sin(a), sin(a) + k * cos(a)),
        control2: transform(cos(b) + k * sin(b), sin(b) - k * cos(b)))
    }
  }
}
