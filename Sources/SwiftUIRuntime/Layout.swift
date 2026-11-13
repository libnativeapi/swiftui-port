/// Deterministic metrics for tests and backends without a text measurer.
/// Windows supplies real font measurement to LayoutEngine instead.
import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// A proposal-based layout shared by deterministic tests and native drawing.
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
public struct LayoutEngine {
  private final class Cache {
    struct Placement {
      let offered: Rect
      let element: Element
    }
    struct Identity {
      let kind: ElementKind
      let props: NodeProps
      let children: [Int]
      let id: Int
      let revision: Int
    }
    var nextID = 1
    var identities: [Int: Identity] = [:]
    var measurements: [Pass.Key: Size] = [:]
    var placements: [Int: Placement] = [:]
    var timings: [String: Double] = [:]
    var passes = 0
    func reset() {
      identities.removeAll()
      measurements.removeAll()
      placements.removeAll()
    }
  }
  private let cache = Cache()
  private final class Pass {
    let prunes: Bool
    init(prunes: Bool) { self.prunes = prunes }
    struct Key: Hashable {
      let id: Int
      let width: CGFloat?, height: CGFloat?
    }
    var liveViews = Set<Int>()
    var liveMeasurements = Set<Int>()
    var horizontal: [Int: Bool] = [:]
    var vertical: [Int: Bool] = [:]
  }
  private var pass: Pass?
  public var lastTimings: [String: Double] { cache.timings }
  public var metrics: TextMetrics { didSet { cache.reset() } }
  public var textMeasurer: ((String, Font) -> Size)? { didSet { cache.reset() } }
  public init(metrics: TextMetrics = .default, textMeasurer: ((String, Font) -> Size)? = nil) {
    self.metrics = metrics
    self.textMeasurer = textMeasurer
  }
  public func measuredSize(of element: Element) -> Size { measure(element) }
  public func sizeThatFits(_ element: Element, proposal: ProposedViewSize) -> CGSize {
    let s = measure(element, proposal)
    return CGSize(width: s.width, height: s.height)
  }
  /// Re-run opaque layout placement before retaining translated content. A
  /// custom Layout may depend on bounds.origin; never assume it is invariant.
  func canTranslateScroll(_ element: Element, dx: Double, dy: Double) -> Bool {
    if element.geometrySnapshot?.dependsOnPosition == true { return false }
    if element.kind == .presentation && element.children.count > 1 { return false }
    if let layout = element.layout {
      var engine = self
      engine.pass = Pass(prunes: false)
      let bounds = CGRect(
        x: element.frame.minX + dx, y: element.frame.minY + dy,
        width: element.frame.width, height: element.frame.height)
      let next = layout.placements(bounds, children: element.children, engine: engine)
      guard next.count == element.customLayoutFrames.count else { return false }
      for (actual, old) in zip(next, element.customLayoutFrames) {
        let expected = old.offsetBy(dx: dx, dy: dy)
        if abs(actual.minX - expected.minX) > 1e-8 || abs(actual.minY - expected.minY) > 1e-8
          || abs(actual.width - expected.width) > 1e-8
          || abs(actual.height - expected.height) > 1e-8
        {
          return false
        }
      }
    }
    return element.children.allSatisfy { canTranslateScroll($0, dx: dx, dy: dy) }
  }
  public func layout(root: inout Element, in size: Size) {
    var engine = self
    cache.passes += 1
    // IDs are never recycled. Reclaim obsolete proposals and snapshots in
    // bounded batches instead of rebuilding three dictionaries on every tick.
    engine.pass = Pass(prunes: cache.passes % 8 == 0)
    var started = Date.timeIntervalSinceReferenceDate
    engine.identify(&root)
    cache.timings["identify"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
    started = Date.timeIntervalSinceReferenceDate
    engine.layoutRoot(root: &root, in: size)
    cache.timings["place"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
    started = Date.timeIntervalSinceReferenceDate
    if engine.pass!.prunes {
      for key in cache.identities.keys.filter({ !engine.pass!.liveViews.contains($0) }) {
        cache.identities.removeValue(forKey: key)
      }
      for key in cache.measurements.keys.filter({ !engine.pass!.liveMeasurements.contains($0.id) })
      {
        cache.measurements.removeValue(forKey: key)
      }
      for key in cache.placements.keys.filter({ !engine.pass!.liveViews.contains($0) }) {
        cache.placements.removeValue(forKey: key)
      }
    }
    cache.timings["prune"] = (Date.timeIntervalSinceReferenceDate - started) * 1000
  }
  private func identify(_ element: inout Element) {
    guard let pass else { return }
    if element.reusesLayout {
      retainIdentities(element)
      return
    }
    for i in element.children.indices { identify(&element.children[i]) }
    element.hasDynamicLayout =
      element.geometryBuilder != nil || element.kind == .presentation || element.layout != nil
      || element.children.contains { $0.hasDynamicLayout }
    element.hasPresentation =
      element.kind == .presentation || element.children.contains { $0.hasPresentation }
    element.hasPreferences =
      element.geometryBuilder != nil || !element.preferences.isEmpty
      || element.preferenceAction != nil || element.children.contains { $0.hasPreferences }
    let children = element.children.map(\.layoutID)
    let opaqueLayout =
      element.layout != nil || element.horizontalGuide != nil || element.verticalGuide != nil
    if element.evaluationID != 0,
      let previous = cache.identities[element.evaluationID],
      !opaqueLayout || previous.revision == element.evaluationRevision,
      previous.kind == element.kind, previous.children == children,
      sameSizing(previous.props, element.props)
    {
      element.layoutID = previous.id
    } else {
      element.layoutID = cache.nextID
      cache.nextID += 1
      if element.evaluationID != 0 {
        cache.identities[element.evaluationID] = Cache.Identity(
          kind: element.kind, props: element.props, children: children, id: element.layoutID,
          revision: element.evaluationRevision)
      }
    }
    if pass.prunes {
      pass.liveViews.insert(element.evaluationID)
      pass.liveMeasurements.insert(element.layoutID)
    }
  }
  private func retainIdentities(_ element: Element) {
    guard pass?.prunes == true else { return }
    pass?.liveViews.insert(element.evaluationID)
    pass?.liveMeasurements.insert(element.layoutID)
    for child in element.children { retainIdentities(child) }
  }
  private func sameSizing(_ a: NodeProps, _ b: NodeProps) -> Bool {
    a.text == b.text && a.font == b.font && a.lineLimit == b.lineLimit
      && a.lineSpacing == b.lineSpacing && a.truncationMode == b.truncationMode
      && a.frameWidth == b.frameWidth && a.frameHeight == b.frameHeight && a.minWidth == b.minWidth
      && a.minHeight == b.minHeight && a.maxWidth == b.maxWidth && a.maxHeight == b.maxHeight
      && a.idealWidth == b.idealWidth && a.idealHeight == b.idealHeight
      && a.fixedWidth == b.fixedWidth && a.fixedHeight == b.fixedHeight
      && a.fillWidth == b.fillWidth && a.fillHeight == b.fillHeight && a.padding == b.padding
      && a.spacing == b.spacing && a.flex == b.flex && a.scrollAxes == b.scrollAxes
      && a.gridUnsizedAxes == b.gridUnsizedAxes && a.visible == b.visible
      && a.multiline == b.multiline && a.offsetX == b.offsetX && a.offsetY == b.offsetY
      && a.scrollOffset == b.scrollOffset && a.alignment == b.alignment
      && a.horizontalAlignment == b.horizontalAlignment
      && a.verticalAlignment == b.verticalAlignment && a.coordinateSpace == b.coordinateSpace
  }
  private func layoutRoot(root: inout Element, in size: Size) {
    let natural = measure(root, ProposedViewSize(width: size.width, height: size.height))
    let extent =
      root.isContainer
      ? size : Size(width: min(natural.width, size.width), height: min(natural.height, size.height))
    place(
      &root,
      in: Rect(
        x: 0, y: 0, width: root.props.frameWidth ?? extent.width,
        height: root.props.frameHeight ?? extent.height))
  }
  private func textSize(_ text: String, _ font: Font?) -> Size {
    textMeasurer?(text, font ?? .body)
      ?? Size(
        width: Double(text.count) * metrics.characterWidth,
        height: font.map { Double($0.size) } ?? metrics.lineHeight)
  }
  private func lines(_ p: NodeProps, width: Double?) -> [String] {
    var result: [String] = []
    for paragraph in p.text.components(separatedBy: "\n") {
      guard let width, width > 0, !p.fixedWidth, p.lineLimit != 1,
        textSize(paragraph, p.font).width > width
      else {
        result.append(paragraph)
        continue
      }
      var line = ""
      for word in paragraph.components(separatedBy: " ") {
        let next = line.isEmpty ? word : line + " " + word
        if !line.isEmpty && textSize(next, p.font).width > width {
          result.append(line)
          line = word
        } else {
          line = next
        }
        while textSize(line, p.font).width > width && line.count > 1 {
          var prefix = ""
          for char in line {
            if !prefix.isEmpty && textSize(prefix + String(char), p.font).width > width { break }
            prefix.append(char)
          }
          result.append(prefix)
          line = String(line.dropFirst(prefix.count))
        }
      }
      result.append(line)
    }
    if let limit = p.lineLimit, result.count > limit {
      result = Array(result.prefix(max(1, limit)))
    }
    if let width, p.lineLimit != nil, !p.fixedWidth {
      result = result.map { line in
        guard textSize(line, p.font).width > width else { return line }
        var value = line
        while !value.isEmpty && textSize(value + "…", p.font).width > width {
          if p.truncationMode == .head { value.removeFirst() } else { value.removeLast() }
        }
        return p.truncationMode == .head ? "…" + value : value + "…"
      }
    }
    return result
  }
  private func measure(_ e: Element, _ proposal: ProposedViewSize = .unspecified) -> Size {
    guard pass != nil, e.layoutID != 0 else { return measureUncached(e, proposal) }
    let key = Pass.Key(id: e.layoutID, width: proposal.width, height: proposal.height)
    if let result = cache.measurements[key] { return result }
    let result = measureUncached(e, proposal)
    cache.measurements[key] = result
    return result
  }
  private func measureUncached(_ e: Element, _ proposal: ProposedViewSize) -> Size {
    let p = e.props
    let width: Double? =
      p.frameWidth ?? proposal.width.map {
        min(p.maxWidth ?? .infinity, max(p.minWidth ?? 0, Double($0)))
      } ?? p.idealWidth
    let height: Double? =
      p.frameHeight ?? proposal.height.map {
        min(p.maxHeight ?? .infinity, max(p.minHeight ?? 0, Double($0)))
      } ?? p.idealHeight
    let offer = ProposedViewSize(
      width: p.fixedWidth ? nil : width.map { CGFloat($0) },
      height: p.fixedHeight ? nil : height.map { CGFloat($0) })
    var size = Size.zero
    switch e.kind {
    case .text, .button:
      let textLines = lines(p, width: e.kind == .button ? nil : offer.width.map { Double($0) })
      let sizes = textLines.map { textSize($0, p.font) }
      size = Size(
        width: sizes.map(\.width).max() ?? 0,
        height: sizes.map(\.height).reduce(0, +) + Double(max(0, sizes.count - 1)) * p.lineSpacing)
      if e.kind == .button {
        size.width += metrics.buttonHorizontalPadding * 2
        size.height += metrics.buttonVerticalPadding * 2
      }
    case .textField:
      size = textSize(p.text.isEmpty ? " " : p.text, p.font)
      size.width = offer.width.map { Double($0) } ?? max(80, size.width)
      size.height = max(size.height, 20) * (p.multiline ? 3 : 1)
    case .image: size = Size(width: 20, height: 20)
    case .padding:
      let child = ProposedViewSize(
        width: offer.width.map { max(0, $0 - p.padding.horizontal) },
        height: offer.height.map { max(0, $0 - p.padding.vertical) })
      size = e.children.first.map { measure($0, child) } ?? .zero
      size.width += p.padding.horizontal
      size.height += p.padding.vertical
    case .presentation, .frame, .layer, .styledButton:
      size = e.children.first.map { measure($0, offer) } ?? .zero
    case .zStack:
      let sizes = e.children.map { measure($0, offer) }
      size = Size(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    case .geometry: size = Size(width: offer.width ?? 10, height: offer.height ?? 10)
    case .grid:
      let columns = gridColumns(e, proposal: offer)
      let heights = e.children.map { row in
        row.children.enumerated().map { i, cell in
          measure(cell, ProposedViewSize(width: columns[i], height: nil)).height
        }.max() ?? 0
      }
      size = Size(
        width: columns.reduce(0, +) + Double(max(0, columns.count - 1)) * p.padding.leading,
        height: heights.reduce(0, +) + Double(max(0, heights.count - 1)) * p.spacing)
    case .customLayout:
      if let layout = e.layout {
        let result = layout.measure(offer, children: e.children, engine: self)
        size = Size(width: result.width, height: result.height)
      }
    case .scroll:
      let content = ProposedViewSize(
        width: p.scrollAxes.contains(.horizontal) ? nil : offer.width,
        height: p.scrollAxes.contains(.vertical) ? nil : offer.height)
      size = e.children.first.map { measure($0, content) } ?? .zero
      if let width = offer.width {
        size.width = min(Double(width), size.width)
      } else if p.scrollAxes.contains(.horizontal) {
        size.width = 10
      }
      if let height = offer.height {
        size.height = min(Double(height), size.height)
      } else if p.scrollAxes.contains(.vertical) {
        size.height = 10
      }
    case .fragment, .container:
      let horizontal = e.kind == .container(.horizontal)
      let children = e.children.filter(\.props.visible)
      let childOffer = ProposedViewSize(
        width: horizontal ? nil : offer.width, height: horizontal ? offer.height : nil)
      let sizes = children.map { measure($0, childOffer) }
      let main =
        sizes.reduce(0) { $0 + (horizontal ? $1.width : $1.height) } + Double(
          max(0, sizes.count - 1)) * p.spacing
      let cross = sizes.reduce(0) { max($0, horizontal ? $1.height : $1.width) }
      size = horizontal ? Size(width: main, height: cross) : Size(width: cross, height: main)
    case .shape, .path, .gradient: size = Size(width: offer.width ?? 0, height: offer.height ?? 0)
    case .spacer, .empty: break
    }
    if p.fillWidth, let width = offer.width, width.isFinite { size.width = width }
    if p.fillHeight, let height = offer.height, height.isFinite { size.height = height }
    size.width = p.frameWidth ?? min(p.maxWidth ?? .infinity, max(p.minWidth ?? 0, size.width))
    size.height = p.frameHeight ?? min(p.maxHeight ?? .infinity, max(p.minHeight ?? 0, size.height))
    if p.gridUnsizedAxes.contains(.horizontal) { size.width = 0 }
    if p.gridUnsizedAxes.contains(.vertical) { size.height = 0 }
    return Size(
      width: size.width.isFinite ? max(0, size.width) : 0,
      height: size.height.isFinite ? max(0, size.height) : 0)
  }
  private func gridColumns(_ e: Element, proposal: ProposedViewSize) -> [Double] {
    let count = e.children.map { $0.children.count }.max() ?? 0
    guard count > 0 else { return [] }
    let available = proposal.width.map {
      max(0, Double($0) - Double(count - 1) * e.props.padding.leading) / Double(count)
    }
    return (0..<count).map { i in
      e.children.compactMap { row -> Double? in
        guard i < row.children.count else { return nil }
        return measure(
          row.children[i], ProposedViewSize(width: available.map { CGFloat($0) }, height: nil)
        ).width
      }.max() ?? 0
    }
  }
  private func fills(_ e: Element, horizontal: Bool) -> Bool {
    guard let pass, e.layoutID != 0 else { return fillsUncached(e, horizontal: horizontal) }
    if let result = horizontal ? pass.horizontal[e.layoutID] : pass.vertical[e.layoutID] {
      return result
    }
    let result = fillsUncached(e, horizontal: horizontal)
    if horizontal {
      pass.horizontal[e.layoutID] = result
    } else {
      pass.vertical[e.layoutID] = result
    }
    return result
  }
  private func fillsUncached(_ e: Element, horizontal: Bool) -> Bool {
    let p = e.props
    if horizontal ? p.frameWidth != nil || p.fixedWidth : p.frameHeight != nil || p.fixedHeight {
      return false
    }
    if horizontal ? p.fillWidth : p.fillHeight { return true }
    switch e.kind {
    case .presentation, .padding, .frame, .layer, .styledButton:
      return e.children.first.map { fills($0, horizontal: horizontal) } ?? false
    case .zStack: return e.children.contains { fills($0, horizontal: horizontal) }
    case .customLayout: return horizontal
    case .container(let axis):
      if (axis == .horizontal) == horizontal {
        return e.children.contains { $0.kind == .spacer || fills($0, horizontal: horizontal) }
      }
      return e.children.contains { fills($0, horizontal: horizontal) }
    default: return false
    }
  }
  private func fit(_ e: Element, in size: Size) -> Size {
    let natural = measure(e, ProposedViewSize(width: size.width, height: size.height))
    let p = e.props
    return Size(
      width: p.frameWidth
        ?? (fills(e, horizontal: true)
          ? max(p.minWidth ?? 0, min(size.width, p.maxWidth ?? .infinity)) : natural.width),
      height: p.frameHeight
        ?? (fills(e, horizontal: false)
          ? max(p.minHeight ?? 0, min(size.height, p.maxHeight ?? .infinity)) : natural.height))
  }
  private func aligned(_ size: Size, in rect: Rect, alignment: Alignment, child: Element? = nil)
    -> Rect
  {
    let dx =
      alignment.horizontal == .leading
      ? 0
      : alignment.horizontal == .trailing ? rect.width - size.width : (rect.width - size.width) / 2
    let dy =
      alignment.vertical == .top
      ? 0
      : alignment.vertical == .bottom ? rect.height - size.height : (rect.height - size.height) / 2
    let dimensions = ViewDimensions(width: size.width, height: size.height)
    return Rect(
      x: rect.minX + dx
        + (child?.horizontalGuide.map { dimensions[alignment.horizontal] - $0(dimensions) } ?? 0),
      y: rect.minY + dy
        + (child?.verticalGuide.map { dimensions[alignment.vertical] - $0(dimensions) } ?? 0),
      width: size.width, height: size.height)
  }
  private func place(_ e: inout Element, in offered: Rect) {
    if e.reusesLayout {
      let origin = Point(x: offered.minX + e.props.offsetX, y: offered.minY + e.props.offsetY)
      let stationary = origin == e.frame.origin && e.layoutContext == GeometryContext.current
      let dx = origin.x - e.frame.minX
      let dy = origin.y - e.frame.minY
      if offered.size == e.frame.size
        && (stationary || e.supportsTranslation || canTranslateScroll(e, dx: dx, dy: dy))
      {
        retainGeometry(e)
        if !stationary {
          translate(&e, dx: origin.x - e.frame.minX, dy: origin.y - e.frame.minY)
        }
        return
      }
      e.reusesLayout = false
    }
    if !e.hasDynamicLayout, e.evaluationID != 0,
      let previous = cache.placements[e.evaluationID],
      previous.offered == offered, previous.element.layoutID == e.layoutID
    {
      applyFrames(&e, from: previous.element)
      return
    }
    defer {
      e.hasPresentation = e.kind == .presentation || e.children.contains { $0.hasPresentation }
      if !e.hasDynamicLayout && e.evaluationID != 0 {
        cache.placements[e.evaluationID] = Cache.Placement(offered: offered, element: e)
      }
    }
    let rect = Rect(
      x: offered.minX + e.props.offsetX, y: offered.minY + e.props.offsetY, width: offered.width,
      height: offered.height)
    e.frame = rect
    e.layoutContext = GeometryContext.current
    let namedOrigins = GeometryContext.current
    if let name = e.props.coordinateSpace {
      GeometryContext.current[name] = CGPoint(x: rect.minX, y: rect.minY)
    }
    defer { GeometryContext.current = namedOrigins }
    switch e.kind {
    case .text: e.props.renderedText = lines(e.props, width: rect.width).joined(separator: "\n")
    case .frame:
      if !e.children.isEmpty {
        let child = e.children[0]
        place(
          &e.children[0],
          in: aligned(
            fit(child, in: rect.size), in: rect, alignment: e.props.alignment, child: child))
      }
    case .padding:
      if !e.children.isEmpty {
        let inner = rect.inset(by: e.props.padding)
        let child = e.children[0]
        let size = child.isContainer ? inner.size : fit(child, in: inner.size)
        place(&e.children[0], in: Rect(origin: inner.origin, size: size))
      }
    case .layer:
      guard e.children.count == 2 else { return }
      place(&e.children[0], in: rect)
      let child = e.children[1]
      place(
        &e.children[1],
        in: aligned(fit(child, in: rect.size), in: rect, alignment: e.props.alignment, child: child)
      )
    case .presentation:
      if !e.children.isEmpty { place(&e.children[0], in: rect) }
      if e.children.count > 1 {
        let size = measure(e.children[1], ProposedViewSize(width: 640, height: nil))
        place(
          &e.children[1],
          in: Rect(x: rect.minX, y: rect.maxY, width: size.width, height: size.height))
      }
    case .styledButton: if !e.children.isEmpty { place(&e.children[0], in: rect) }
    case .zStack:
      for i in e.children.indices {
        let child = e.children[i]
        place(
          &e.children[i],
          in: aligned(
            fit(child, in: rect.size), in: rect, alignment: e.props.alignment, child: child))
      }
    case .geometry:
      if let builder = e.geometryBuilder {
        let snapshot = GeometrySnapshot(
          rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
          namedOrigins: GeometryContext.current)
        snapshot.capture {
          var child = builder(
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
          resolveEnvironment(
            &child, inheritedForeground: e.props.foreground, inheritedDisabled: !e.props.enabled,
            inheritedOpacity: e.props.opacity, inheritedVisible: e.props.visible,
            inheritedLineLimit: e.props.lineLimit, inheritedLineSpacing: e.props.lineSpacing)
          identify(&child)
          e.children = [child]
          place(&e.children[0], in: rect)
        }
        e.geometrySnapshot = snapshot
        e.hasPresentation = e.children.contains { $0.hasPresentation }
      }
    case .grid:
      let columns = gridColumns(
        e, proposal: ProposedViewSize(width: rect.width, height: rect.height))
      var y = rect.minY
      for row in e.children.indices {
        // Grid places row children directly, bypassing place(row). Their
        // proposals can change even when the row's outer frame stays fixed.
        // Reconcile the row so rebuilt GeometryReader content receives keys
        // and mounted IDs instead of retaining placeholder IDs.
        e.children[row].reusesLayout = false
        let height =
          e.children[row].children.enumerated().map { i, cell in
            measure(cell, ProposedViewSize(width: columns[i], height: nil)).height
          }.max() ?? 0
        e.children[row].frame = Rect(x: rect.minX, y: y, width: rect.width, height: height)
        var x = rect.minX
        for col in e.children[row].children.indices {
          place(
            &e.children[row].children[col],
            in: Rect(x: x, y: y, width: columns[col], height: height))
          x += columns[col] + e.props.padding.leading
        }
        y += height + e.props.spacing
      }
    case .customLayout:
      if let layout = e.layout {
        let frames = layout.placements(
          CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
          children: e.children, engine: self)
        e.customLayoutFrames = frames
        for i in e.children.indices {
          let f = frames[i]
          place(&e.children[i], in: Rect(x: f.minX, y: f.minY, width: f.width, height: f.height))
        }
      }
    case .scroll:
      guard !e.children.isEmpty else { return }
      let natural = measure(
        e.children[0],
        ProposedViewSize(
          width: e.props.scrollAxes.contains(.horizontal) ? nil : rect.width,
          height: e.props.scrollAxes.contains(.vertical) ? nil : rect.height))
      let size = Size(
        width: max(rect.width, natural.width), height: max(rect.height, natural.height))
      let offset = Point(
        x: max(0, min(e.props.scrollOffset.x, size.width - rect.width)),
        y: max(0, min(e.props.scrollOffset.y, size.height - rect.height)))
      e.props.scrollOffset = offset
      place(
        &e.children[0],
        in: Rect(
          x: rect.minX - offset.x, y: rect.minY - offset.y, width: size.width, height: size.height))
    case .container(let axis): placeStack(&e, axis: axis, in: rect)
    case .fragment: placeStack(&e, axis: .vertical, in: rect)
    default: break
    }
  }
  private func placeStack(_ e: inout Element, axis: Axis, in rect: Rect) {
    let vertical = axis == .vertical
    let visible = e.children.indices.filter { e.children[$0].props.visible }
    let mainExtent = vertical ? rect.height : rect.width
    let crossExtent = vertical ? rect.width : rect.height
    let proposal = ProposedViewSize(
      width: vertical ? rect.width : nil, height: vertical ? nil : rect.height)
    var fixed = Double(max(0, visible.count - 1)) * e.props.spacing
    var flexTotal = 0.0
    for i in visible {
      let child = e.children[i]
      if child.props.flex > 0 || fills(child, horizontal: !vertical) {
        flexTotal += max(1, child.props.flex)
      } else {
        let size = measure(child, proposal)
        fixed += vertical ? size.height : size.width
      }
    }
    var cursor = vertical ? rect.minY : rect.minX
    for i in visible {
      let child = e.children[i]
      let natural = measure(child, proposal)
      let flexible = child.props.flex > 0 || fills(child, horizontal: !vertical)
      let main =
        flexible
        ? max(0, mainExtent - fixed) * max(1, child.props.flex) / max(1, flexTotal)
        : (vertical ? natural.height : natural.width)
      let cross =
        fills(child, horizontal: vertical) || child.props.flex > 0
        ? crossExtent : min(crossExtent, vertical ? natural.width : natural.height)
      let size = vertical ? Size(width: cross, height: main) : Size(width: main, height: cross)
      let slot =
        vertical
        ? Rect(x: rect.minX, y: cursor, width: crossExtent, height: main)
        : Rect(x: cursor, y: rect.minY, width: main, height: crossExtent)
      place(
        &e.children[i],
        in: aligned(
          size, in: slot,
          alignment: Alignment(
            horizontal: e.props.horizontalAlignment, vertical: e.props.verticalAlignment),
          child: child))
      cursor += main + e.props.spacing
    }
    for i in e.children.indices where !e.children[i].props.visible { e.children[i].frame = .zero }
  }
  private func applyFrames(_ element: inout Element, from previous: Element) {
    if element.frame != previous.frame { element.reusesLayout = false }
    element.frame = previous.frame
    element.props.renderedText = previous.props.renderedText
    element.props.scrollOffset = previous.props.scrollOffset
    for i in element.children.indices {
      applyFrames(&element.children[i], from: previous.children[i])
    }
  }
  private func translate(_ element: inout Element, dx: Double, dy: Double) {
    element.reusesLayout = false
    element.frame.origin.x += dx
    element.frame.origin.y += dy
    element.customLayoutFrames = element.customLayoutFrames.map { $0.offsetBy(dx: dx, dy: dy) }
    element.layoutContext = GeometryContext.current
    let saved = GeometryContext.current
    if let name = element.props.coordinateSpace {
      GeometryContext.current[name] = CGPoint(x: element.frame.minX, y: element.frame.minY)
    }
    defer { GeometryContext.current = saved }
    if let snapshot = element.geometrySnapshot {
      snapshot.rect.origin = CGPoint(x: element.frame.minX, y: element.frame.minY)
      snapshot.namedOrigins = GeometryContext.current
    }
    for i in element.children.indices { translate(&element.children[i], dx: dx, dy: dy) }
  }
  private func retainGeometry(_ element: Element) {
    if let snapshot = element.geometrySnapshot {
      snapshot.retain()
      return
    }
    for child in element.children where child.hasDynamicLayout { retainGeometry(child) }
  }
}
