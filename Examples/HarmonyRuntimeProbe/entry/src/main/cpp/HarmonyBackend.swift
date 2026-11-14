import Foundation
import SwiftUIRuntime

public typealias HarmonyUpdate = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Void

@_silgen_name("harmony_measure_text")
private func harmonyMeasureText(
  _ text: UnsafePointer<CChar>, _ family: UnsafePointer<CChar>, _ fontSize: Double,
  _ weight: Int32, _ width: UnsafeMutablePointer<Double>, _ height: UnsafeMutablePointer<Double>
) -> Bool

final class HarmonyBackend: RenderBackend {
  var tapHandler: ((NodeID) -> Void)?
  var needsRenderCommands: Bool { false }

  private let context: UnsafeMutableRawPointer
  private let update: HarmonyUpdate
  private let pixelsPerPoint: Double

  private struct TextKey: Hashable {
    var text: String
    var font: Font
  }
  private var textSizes: [TextKey: Size] = [:]

  init(context: UnsafeMutableRawPointer, update: @escaping HarmonyUpdate, pixelsPerPoint: Double) {
    self.context = context
    self.update = update
    self.pixelsPerPoint = pixelsPerPoint
  }

  func measureText(_ text: String, _ font: Font) -> Size {
    let key = TextKey(text: text, font: font)
    if let cached = textSizes[key] { return cached }
    var width = 0.0
    var height = 0.0
    let measured = text.withCString { string in
      fontFamily(font).withCString { family in
        harmonyMeasureText(string, family, font.size * pixelsPerPoint,
                           Int32(fontWeight(font) / 100 - 1), &width, &height)
      }
    }
    let size = measured ? Size(width: width / pixelsPerPoint, height: height / pixelsPerPoint)
      : Size(width: Double(text.count) * font.size / 2, height: font.size)
    if textSizes.count >= 8192 { textSizes.removeAll(keepingCapacity: true) }
    textSizes[key] = size
    return size
  }

  private func fontFamily(_ font: Font) -> String {
    switch font.family {
    case "Segoe UI": return ""
    case "Consolas": return "monospace"
    case "Georgia": return "serif"
    default: return font.family
    }
  }

  private func fontWeight(_ font: Font) -> Int {
    guard font.weight.value.isFinite else { return 400 }
    return Int((min(900, max(100, font.weight.value)) / 100).rounded()) * 100
  }

  func perform(_ commands: [RenderCommand]) {}

  func didRender(_ root: Element) {
    let tree = snapshot(root)
    guard let data = try? JSONEncoder().encode(tree) else { return }
    String(decoding: data, as: UTF8.self).withCString { update(context, $0) }
  }

  private struct Node: Encodable {
    var id: Int
    var kind: String
    var x, y, width, height: Double
    var text: String
    var label: String
    var placeholder: String
    var image: String
    var fontSize: Double
    var fontWeight: Int
    var fontFamily: String
    var textAlignment: String
    var lineSpacing: Double
    var tracking: Double
    var underline: Bool
    var lineLimit: Int
    var path: String
    var clipPath: String?
    var rotation, scaleX, scaleY: Double
    var dash: [Double]
    var foreground: UInt32?
    var background: UInt32?
    var border: UInt32?
    var borderWidth: Double
    var radius: Double
    var opacity: Double
    var clip: Bool
    var scrollIndicators: Bool
    var scrollDirection: String
    var selected: Bool
    var enabled: Bool
    var hitTesting: Bool
    var children: [Node]
  }

  private func snapshot(_ element: Element) -> Node {
    let props = element.props
    let font = props.font ?? .body
    let frame = element.frame
    let localFrame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
    let children = element.children.enumerated().sorted {
      if $0.element.props.zIndex != $1.element.props.zIndex {
        return $0.element.props.zIndex < $1.element.props.zIndex
      }
      return props.layerBehind ? $0.offset > $1.offset : $0.offset < $1.offset
    }.map(\.element)
    func number(_ value: Double) -> Double { value.isFinite ? value : 0 }
    func color(_ value: Color?) -> UInt32? {
      value.map { color in
        [color.opacity, color.red, color.green, color.blue].reduce(0) {
          ($0 << 8) | UInt32((max(0, min(1, number($1))) * 255).rounded())
        }
      }
    }
    let kind: String
    var path = ""
    switch element.kind {
    case .text: kind = "text"
    case .button, .styledButton: kind = "button"
    case .textField: kind = "editor"
    case .image: kind = "image"
    case .scroll: kind = "scroll"
    case .path, .shape:
      if let builder = element.pathBuilder {
        path = commands(builder(localFrame))
      } else if element.kind == .path {
        path = commands(props.path)
      }
      kind = path.isEmpty ? "group" : "path"
    default: kind = "group"
    }
    return Node(
      id: element.id.rawValue, kind: kind,
      x: number(frame.minX), y: number(frame.minY), width: number(frame.width), height: number(frame.height),
      text: props.renderedText ?? props.text,
      label: kind == "button" ? buttonLabel(element) : props.accessibilityLabel,
      placeholder: props.placeholder, image: props.imagePath,
      fontSize: number(font.size), fontWeight: fontWeight(font), fontFamily: fontFamily(font),
      textAlignment: props.textAlignment == .center ? "center" : props.textAlignment == .trailing ? "end" : "start",
      lineSpacing: number(props.lineSpacing), tracking: number(props.tracking), underline: props.underline,
      lineLimit: props.lineLimit ?? 0, path: path,
      clipPath: element.clipPathBuilder.map { commands($0(localFrame)) },
      rotation: number(props.rotation), scaleX: number(props.scaleX), scaleY: number(props.scaleY),
      dash: props.dash.map(number),
      foreground: color(props.foreground),
      background: color(props.background), border: color(props.borderColor),
      borderWidth: number(props.borderWidth),
      radius: number(min(props.cornerRadius, frame.width / 2, frame.height / 2)),
      opacity: number(props.opacity), clip: props.clipped,
      scrollIndicators: props.showsScrollIndicators,
      scrollDirection: props.scrollAxes.contains(.horizontal)
        ? (props.scrollAxes.contains(.vertical) ? "both" : "horizontal") : "vertical",
      selected: AccessibilityTraits(rawValue: props.accessibilityTraits).contains(.isSelected),
      enabled: props.enabled, hitTesting: props.hitTesting,
      children: children.filter { $0.props.visible }.map(snapshot))
  }

  private func buttonLabel(_ element: Element) -> String {
    if !element.props.accessibilityLabel.isEmpty { return element.props.accessibilityLabel }
    if !element.props.text.isEmpty { return element.props.text }
    return element.children.map(buttonLabel).filter { !$0.isEmpty }.joined(separator: " ")
  }

  private func commands(_ path: Path) -> String {
    var parts: [String] = []
    var index = 0
    while index < path.commands.count {
      let command: String, points: Int
      switch path.commands[index] {
      case 0: (command, points) = ("M", 2)
      case 1: (command, points) = ("L", 2)
      case 2: (command, points) = ("C", 6)
      case 3: (command, points) = ("Z", 0)
      default: return ""
      }
      let end = index + 1 + points
      guard end <= path.commands.count else { return "" }
      let values = path.commands[(index + 1)..<end].map { $0 * pixelsPerPoint }
      guard values.allSatisfy(\.isFinite) else { return "" }
      parts.append(command + values.map { String($0) }.joined(separator: " "))
      index = end
    }
    return parts.joined(separator: " ")
  }
}
