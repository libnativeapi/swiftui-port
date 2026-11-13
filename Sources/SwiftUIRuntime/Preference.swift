import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public protocol PreferenceKey {
  associatedtype Value
  static var defaultValue: Value { get }
  static func reduce(value: inout Value, nextValue: () -> Value)
}
struct PreferenceValue {
  var value: Any
  let reduce: (Any, Any) -> Any
}
struct PreferenceReader<Content: View, Key: PreferenceKey>: View, _PrimitiveView
where Key.Value: Equatable {
  typealias Body = Never
  let content: Content
  let action: (Key.Value) -> Void
  @State private var previous: Key.Value?
  var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var element = _render(content, path: path)
    let old = element.preferenceAction
    element.preferenceAction = { values in
      old?(values)
      let next = values[ObjectIdentifier(Key.self)]?.value as? Key.Value ?? Key.defaultValue
      if previous != next {
        previous = next
        action(next)
      }
    }
    return element
  }
}
extension View {
  public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
    TransformView(content: self) { node in
      node.preferences[ObjectIdentifier(K.self)] = PreferenceValue(
        value: value,
        reduce: { old, new in
          var value = old as! K.Value
          K.reduce(value: &value, nextValue: { new as! K.Value })
          return value
        })
    }
  }
  public func onPreferenceChange<K: PreferenceKey>(
    _ key: K.Type = K.self, perform action: @escaping (K.Value) -> Void
  ) -> some View where K.Value: Equatable {
    PreferenceReader<Self, K>(content: self, action: action)
  }
}
func resolvePreferences(_ node: Element) -> [ObjectIdentifier: PreferenceValue] {
  if !node.hasPreferences { return [:] }
  var result = node.preferences
  for child in node.children {
    for (key, value) in resolvePreferences(child) {
      if let old = result[key] {
        result[key] = PreferenceValue(
          value: value.reduce(old.value, value.value), reduce: value.reduce)
      } else {
        result[key] = value
      }
    }
  }
  if let action = node.preferenceAction {
    let values = result
    LifecycleRegistry.shared.pending.append { action(values) }
  }
  return result
}
public struct GridItem {
  public enum Size {
    case fixed(CGFloat)
    case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
    case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
  }
  public let size: Size
  public let spacing: CGFloat?
  public let alignment: Alignment?
  public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
    self.size = size
    self.spacing = spacing
    self.alignment = alignment
  }
}
public struct LazyVGrid<Content: View>: View {
  let columns: [GridItem]
  let spacing: CGFloat
  let content: Content
  public init(
    columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.columns = columns
    self.spacing = spacing ?? 8
    self.content = content()
  }
  public var body: some View { GridLayout(columns: columns, spacing: spacing) { content } }
}
private struct GridLayout: Layout {
  let columns: [GridItem]
  let spacing: CGFloat
  func widths(_ proposal: ProposedViewSize) -> [CGFloat] {
    let width = proposal.width ?? 500
    if columns.count == 1, case .adaptive(let minimum, let maximum) = columns[0].size {
      let n = max(1, Int((width + spacing) / (minimum + spacing)))
      return Array(
        repeating: min(maximum, (width - CGFloat(n - 1) * spacing) / CGFloat(n)), count: n)
    }
    let flexible = columns.filter {
      if case .fixed = $0.size { return false }
      return true
    }.count
    let fixed = columns.reduce(CGFloat(0)) { sum, column in
      if case .fixed(let w) = column.size { return sum + w }
      return sum
    }
    let remaining =
      max(0, width - fixed - CGFloat(max(0, columns.count - 1)) * spacing)
      / CGFloat(max(1, flexible))
    return columns.map {
      switch $0.size {
      case .fixed(let w): return w
      case .flexible(let min, let max), .adaptive(let min, let max):
        return Swift.min(max, Swift.max(min, remaining))
      }
    }
  }
  func frames(_ proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
    let widths = widths(proposal)
    guard !widths.isEmpty else { return [] }
    var frames: [CGRect] = []
    var y: CGFloat = 0
    for start in stride(from: 0, to: subviews.count, by: widths.count) {
      let end = min(start + widths.count, subviews.count)
      let heights = (start..<end).map {
        subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0 - start], height: nil)).height
      }
      let height = heights.max() ?? 0
      var x: CGFloat = 0
      for i in start..<end {
        let w = widths[i - start]
        frames.append(CGRect(x: x, y: y, width: w, height: height))
        x += w + spacing
      }
      y += height + spacing
    }
    return frames
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(proposal, subviews: subviews)
    return CGSize(
      width: frames.map { $0.maxX }.max() ?? 0, height: frames.map { $0.maxY }.max() ?? 0)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (i, r) in frames(proposal, subviews: subviews).enumerated() {
      subviews[i].place(
        at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY),
        proposal: ProposedViewSize(r.size))
    }
  }
}
public struct Transaction {
  public var animation: Animation?
  public init(animation: Animation? = nil) { self.animation = animation }
}
extension View {
  public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View {
    TransformView(content: self) { node in
      var transaction = Transaction(animation: node.props.animation)
      transform(&transaction)
      node.props.animation = transaction.animation
    }
  }
}
