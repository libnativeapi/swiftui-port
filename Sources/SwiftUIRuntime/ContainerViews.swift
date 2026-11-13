import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public struct ZStack<Content: View>: View, _PrimitiveView {
  public typealias Body = Never
  let content: Content
  let alignment: Alignment
  public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
    self.alignment = alignment
    self.content = content()
  }
  public var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var props = NodeProps()
    props.alignment = alignment
    return Element(
      kind: .zStack, props: props, children: flattenChildren(_render(content, path: path)))
  }
}
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View,
  _PrimitiveView
{
  public typealias Body = Never
  let data: Data
  let id: KeyPath<Data.Element, ID>
  let content: (Data.Element) -> Content
  public init(
    _ data: Data, id: KeyPath<Data.Element, ID>,
    @ViewBuilder content: @escaping (Data.Element) -> Content
  ) {
    self.data = data
    self.id = id
    self.content = content
  }
  public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content)
  where Data.Element: Identifiable, Data.Element.ID == ID {
    self.init(data, id: \.id, content: content)
  }
  public var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    Element(
      kind: .fragment,
      children: data.map { item in
        var child = _render(content(item), path: path.appending(id: AnyHashable(item[keyPath: id])))
        child.explicitID = AnyHashable(item[keyPath: id])
        return child
      })
  }
}
extension ForEach where Data == Range<Int>, ID == Int {
  public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
    self.init(data, id: \.self, content: content)
  }
}
public struct ScrollView<Content: View>: View, _PrimitiveView {
  public typealias Body = Never
  let axes: Axis.Set
  let content: Content
  let showsIndicators: Bool
  @State private var offset = Point.zero
  public init(
    _ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content
  ) {
    self.axes = axes
    self.content = content()
    self.showsIndicators = showsIndicators
  }
  public var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var p = NodeProps()
    p.scrollAxes = axes
    p.scrollOffset = offset
    p.clipped = true
    p.showsScrollIndicators = showsIndicators
    p.fillWidth = true
    p.fillHeight = axes.contains(.vertical)
    let child =
      EvaluationGraph.active?.withStoredContent { _render(content, path: path.appending(index: 0)) }
      ?? _render(content, path: path.appending(index: 0))
    var result = Element(kind: .scroll, props: p, children: [child])
    result.scrollAction = { offset = $0 }
    result.scrollStateKey = _offset.installedKey
    return result
  }
}
public enum CoordinateSpace {
  case local, global
  case named(AnyHashable)
}
public struct GeometryProxy {
  let snapshot: GeometrySnapshot
  public var size: CGSize { snapshot.rect.size }
  public func frame(in space: CoordinateSpace) -> CGRect {
    switch space {
    case .local: return CGRect(origin: .zero, size: size)
    case .global:
      snapshot.dependsOnPosition = true
      return snapshot.rect
    case .named(let name):
      snapshot.dependsOnPosition = true
      let anchor = snapshot.namedOrigins[name] ?? .zero
      return CGRect(
        x: snapshot.rect.minX - anchor.x, y: snapshot.rect.minY - anchor.y,
        width: size.width, height: size.height)
    }
  }
}
extension CoordinateSpace {
  fileprivate var isLocal: Bool {
    if case .local = self { return true }
    return false
  }
}
public struct GeometryReader<Content: View>: View, _PrimitiveView {
  public typealias Body = Never
  let content: (GeometryProxy) -> Content
  public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }
  public var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    let environment = EnvironmentValues.current
    var p = NodeProps()
    p.fillWidth = true
    p.fillHeight = true
    var result = Element(kind: .geometry, props: p)
    result.geometryBuilder = { rect in
      let saved = EnvironmentValues.current
      EnvironmentValues.current = environment
      defer { EnvironmentValues.current = saved }
      return normalize(
        _render(
          content(
            GeometryProxy(
              snapshot: GeometrySnapshot.active
                ?? GeometrySnapshot(rect: rect, namedOrigins: GeometryContext.current))),
          path: path.appending(index: 0)))
    }
    return result
  }
}
public typealias LazyVStack = VStack
public typealias LazyHStack = HStack
public struct ProposedViewSize {
  public var width: CGFloat?, height: CGFloat?
  public init(width: CGFloat?, height: CGFloat?) {
    self.width = width
    self.height = height
  }
  public init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
  public static let unspecified = ProposedViewSize(width: nil, height: nil)
  public static let zero = ProposedViewSize(.zero)
  public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)
  public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10))
    -> CGSize
  { CGSize(width: width ?? size.width, height: height ?? size.height) }
}
public struct UnitPoint: Equatable {
  public var x: CGFloat, y: CGFloat
  public init(x: CGFloat, y: CGFloat) {
    self.x = x
    self.y = y
  }
  public static let center = UnitPoint(x: 0.5, y: 0.5), topLeading = UnitPoint(x: 0, y: 0),
    topTrailing = UnitPoint(x: 1, y: 0)
  public static let leading = UnitPoint(x: 0, y: 0.5), trailing = UnitPoint(x: 1, y: 0.5)
  public static let top = UnitPoint(x: 0.5, y: 0), bottom = UnitPoint(x: 0.5, y: 1)
  public static let bottomLeading = UnitPoint(x: 0, y: 1), bottomTrailing = UnitPoint(x: 1, y: 1)
}
public final class LayoutSubview {
  let measure: (ProposedViewSize) -> CGSize
  var placement: (CGPoint, UnitPoint, ProposedViewSize)?
  init(measure: @escaping (ProposedViewSize) -> CGSize) { self.measure = measure }
  public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { measure(proposal) }
  public func place(at point: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize)
  { placement = (point, anchor, proposal) }
}
public typealias LayoutSubviews = [LayoutSubview]
public protocol Layout {
  associatedtype Cache = Void
  typealias Subviews = LayoutSubviews
  func makeCache(subviews: Subviews) -> Cache
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
}
extension Layout where Cache == Void { public func makeCache(subviews: Subviews) {} }
extension Layout {
  public func callAsFunction<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    LayoutContainer(layout: self, content: content())
  }
}
protocol _LayoutBridge {
  func measure(_ proposal: ProposedViewSize, children: [Element], engine: LayoutEngine) -> CGSize
  func placements(_ bounds: CGRect, children: [Element], engine: LayoutEngine) -> [CGRect]
}
struct LayoutBridge<L: Layout>: _LayoutBridge {
  let layout: L
  func subviews(_ children: [Element], engine: LayoutEngine) -> LayoutSubviews {
    children.map { child in LayoutSubview { p in engine.sizeThatFits(child, proposal: p) } }
  }
  func measure(_ proposal: ProposedViewSize, children: [Element], engine: LayoutEngine) -> CGSize {
    let views = subviews(children, engine: engine)
    var cache = layout.makeCache(subviews: views)
    return layout.sizeThatFits(proposal: proposal, subviews: views, cache: &cache)
  }
  func placements(_ bounds: CGRect, children: [Element], engine: LayoutEngine) -> [CGRect] {
    let views = subviews(children, engine: engine)
    var cache = layout.makeCache(subviews: views)
    layout.placeSubviews(
      in: bounds, proposal: ProposedViewSize(bounds.size), subviews: views, cache: &cache)
    return views.map { view in
      guard let (point, anchor, proposal) = view.placement else { return .zero }
      let size = view.sizeThatFits(proposal)
      return CGRect(
        x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height, width: size.width,
        height: size.height)
    }
  }
}
struct LayoutContainer<L: Layout, Content: View>: View, _PrimitiveView {
  typealias Body = Never
  let layout: L
  let content: Content
  var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var result = Element(
      kind: .customLayout, children: flattenChildren(_render(content, path: path)))
    result.layout = LayoutBridge(layout: layout)
    return result
  }
}
public struct AnyLayout: Layout {
  let measure: (ProposedViewSize, Subviews) -> CGSize
  let place: (CGRect, ProposedViewSize, Subviews) -> Void
  public init<L: Layout>(_ layout: L) {
    measure = { proposal, views in
      var cache = layout.makeCache(subviews: views)
      return layout.sizeThatFits(proposal: proposal, subviews: views, cache: &cache)
    }
    place = { bounds, proposal, views in
      var cache = layout.makeCache(subviews: views)
      layout.placeSubviews(in: bounds, proposal: proposal, subviews: views, cache: &cache)
    }
  }
  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
    -> CGSize
  { measure(proposal, subviews) }
  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) { place(bounds, proposal, subviews) }
}
public struct HStackLayout: Layout {
  let alignment: VerticalAlignment
  let spacing: CGFloat
  public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil) {
    self.alignment = alignment
    self.spacing = spacing ?? 8
  }
  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
    -> CGSize
  {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    return CGSize(
      width: sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing,
      height: sizes.map { $0.height }.max() ?? 0)
  }
  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      let y =
        alignment == .top
        ? bounds.minY
        : alignment == .bottom ? bounds.maxY - size.height : bounds.midY - size.height / 2
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
    }
  }
}
public struct VStackLayout: Layout {
  let alignment: HorizontalAlignment
  let spacing: CGFloat
  public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) {
    self.alignment = alignment
    self.spacing = spacing ?? 8
  }
  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
    -> CGSize
  {
    let sizes = subviews.map {
      $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    }
    return CGSize(
      width: sizes.map { $0.width }.max() ?? 0,
      height: sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * spacing)
  }
  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      let x =
        alignment == .leading
        ? bounds.minX
        : alignment == .trailing ? bounds.maxX - size.width : bounds.midX - size.width / 2
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      y += size.height + spacing
    }
  }
}
public struct GridRow<Content: View>: View {
  let alignment: VerticalAlignment
  let content: Content
  public init(alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
    self.alignment = alignment
    self.content = content()
  }
  public var body: some View { HStack(alignment: alignment, spacing: 0) { content } }
}
public struct Grid<Content: View>: View, _PrimitiveView {
  public typealias Body = Never
  let alignment: Alignment
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat
  let content: Content
  public init(
    alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil,
    verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> Content
  ) {
    self.alignment = alignment
    self.horizontalSpacing = horizontalSpacing ?? 8
    self.verticalSpacing = verticalSpacing ?? 8
    self.content = content()
  }
  public var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var p = NodeProps()
    p.alignment = alignment
    p.spacing = verticalSpacing
    p.padding.leading = horizontalSpacing
    return Element(kind: .grid, props: p, children: flattenChildren(_render(content, path: path)))
  }
}
extension View {
  public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View {
    TransformView(content: self) { $0.props.gridUnsizedAxes = axes }
  }
}
enum GeometryContext { static var current: [AnyHashable: CGPoint] = [:] }
