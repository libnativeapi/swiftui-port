/// Owns the mounted tree, state invalidation, layout and backend commands.
///
/// ```swift
/// let backend = FakeBackend()
/// let renderer = Renderer(backend: backend, root: AnyView(MyView()), size: Size(width: 320, height: 200))
/// renderer.mount()
/// // ... tap a button or write state ...
/// renderer.renderIfNeeded()
/// ```
///
/// Rendering is synchronous on the calling thread, which must be the UI thread
/// in a real app.

import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

@MainActor @preconcurrency public final class Renderer {
  public let backend: any RenderBackend
  public let layoutEngine: LayoutEngine

  private let root: AnyView
  private let rootPath = ViewPath()
  private var allocator = NodeIDAllocator()
  private var mounted: Element?
  private var normalized: Element?
  private var hoverActions: [NodeID: (Bool) -> Void] = [:]
  private var isRendering = false
  private var needsRender = false
  private var pendingAnimation: Animation?
  private var transactionDepth = 0
  private let evaluations = EvaluationGraph()
  private var contentSize: Size
  private var hoveredNodeIDs: [NodeID] = []
  private var focused: NodeID?
  private var dragging: (id: NodeID, start: CGPoint, origin: CGPoint)?
  private var scrollDrag: (id: NodeID, start: CGPoint, offset: Point, ratio: Double)?
  private var pointerDown: NodeID?
  private var unpublishedOffsets: [NodeID: Point] = [:]
  private var hoverPending = false
  private var hoverPoint: CGPoint?
  private var pendingScroll: (id: NodeID, key: StateKey, offset: Point)?

  /// The last mounted element tree, with frames from the reference layout.
  public private(set) var tree: Element?
  /// The commands produced by the most recent render pass.
  public private(set) var lastCommands: [RenderCommand] = []
  /// Milliseconds spent in each stage of the most recent render transaction.
  public private(set) var lastTimings: [String: Double] = [:]

  public init(
    backend: any RenderBackend,
    root: AnyView,
    size: Size,
    layoutEngine: LayoutEngine = LayoutEngine()
  ) {
    self.backend = backend
    self.root = root
    self.contentSize = size
    self.layoutEngine = layoutEngine
    StateRegistry.shared.onChange = { [weak self] in
      self?.pendingScroll = nil
      self?.evaluations.invalidateAll()
      self?.scheduleRender()
    }
    StateRegistry.shared.onStateChange = { [weak self] key in
      if self?.pendingScroll?.key != key { self?.pendingScroll = nil }
      self?.evaluations.invalidate(key)
      self?.scheduleRender()
    }
    backend.tapHandler = { [weak self] id in
      self?.performTap(id)
    }
    backend.transactionHandler = { [weak self] action in
      guard let self else {
        action()
        return
      }
      self.transactionDepth += 1
      defer { self.finishTransaction() }
      action()
    }
  }

  /// Builds and mounts the initial tree.
  public func mount() {
    guard mounted == nil else {
      renderIfNeeded()
      return
    }

    isRendering = true
    let newTree = buildTree()
    var commands: [RenderCommand]? = backend.needsRenderCommands ? [] : nil
    let mountedTree = createSubtree(
      newTree,
      parent: nil,
      index: 0,
      commands: &commands,
      allocator: &allocator
    )
    mounted = mountedTree
    tree = mountedTree
    rebuildActions(from: mountedTree)
    lastCommands = commands ?? []
    if let commands { backend.perform(commands) }
    backend.didRender(mountedTree)
    LifecycleRegistry.shared.commit()
    isRendering = false

    if needsRender {
      renderIfNeeded()
    }
  }

  /// Updates the available content area and re-renders if it changed.
  public func resize(to size: Size) {
    guard size != contentSize else { return }
    contentSize = size
    pendingScroll = nil
    scheduleRender()
  }

  /// Marks the tree dirty and renders now unless already inside a render pass.
  public func setNeedsRender() {
    pendingScroll = nil
    // Explicit host invalidation may follow changes outside tracked wrappers.
    evaluations.invalidateAll()
    scheduleRender()
  }
  private func scheduleRender() {
    if let animation = AnimationContext.current { pendingAnimation = animation }
    needsRender = true
    if isRendering || transactionDepth > 0 { return }
    requestRender()
  }
  private func requestRender() {
    if !backend.requestRender({ [weak self] in
      guard let self, self.needsRender else { return }
      self.renderIfNeeded()
    }) {
      renderIfNeeded()
    }
  }
  private func finishTransaction() {
    if transactionDepth == 1 && hoverPending {
      hoverPending = false
      let chain =
        hoverPoint.flatMap { point in tree.map { hitChain($0, point: point, hover: true) } } ?? []
      updateHover(chain)
    }
    transactionDepth -= 1
    if transactionDepth == 0 && needsRender && !isRendering { requestRender() }
  }

  /// Runs a render pass if one is pending. Coalesces writes made during a pass
  /// into at most eight follow-up passes, then stops to avoid a render loop.
  public func renderIfNeeded() {
    guard mounted != nil else {
      mount()
      return
    }

    var passes = 0
    repeat {
      needsRender = false
      update()
      backend.didMeasureRender(lastTimings)
      unpublishedOffsets.removeAll(keepingCapacity: true)
      passes += 1
    } while needsRender && passes < 8
  }

  /// Invokes the current action registered for a native button.
  public func performTap(_ id: NodeID) {
    transactionDepth += 1
    defer { finishTransaction() }
    guard let node = find(id, in: tree), node.props.enabled, node.props.visible,
      node.props.hitTesting
    else { return }
    node.action?()
  }

  public enum Interaction {
    case hover(Bool)
    case focus(Bool)
    case pressed(Bool)
  }
  public func interact(_ id: NodeID, _ interaction: Interaction) {
    if case .hover(let value) = interaction,
      hoveredNodeIDs.contains(id) == value
    {
      return
    }
    transactionDepth += 1
    defer { finishTransaction() }
    guard let node = find(id, in: tree) else { return }
    var chain: [Element] = []
    _ = ancestry(id, in: tree, into: &chain)
    switch interaction {
    case .hover(let value):
      if value && node.props.enabled {
        updateHover(chain)
      } else if hoveredNodeIDs.contains(id) {
        updateHover([])
      }
    case .focus(let value):
      if value { focused = id } else if focused == id { focused = nil }
      chain.forEach { $0.focusAction?(value) }
    case .pressed(let value): node.pressedAction?(value && node.props.enabled)
    }
  }
  private func updateHover(_ chain: [Element]) {
    let previous = Set(hoveredNodeIDs)
    let next = Set(chain.map(\.id))
    let old = hoveredNodeIDs
    hoveredNodeIDs = chain.map(\.id)
    for id in old where !next.contains(id) {
      hoverActions[id]?(false)
    }
    for node in chain where !previous.contains(node.id) { node.hoverAction?(true) }
  }
  private func find(_ id: NodeID, in node: Element?) -> Element? {
    guard let node else { return nil }
    if node.id == id { return node }
    for child in node.children { if let found = find(id, in: child) { return found } }
    return nil
  }
  private func ancestry(_ id: NodeID, in node: Element?, into result: inout [Element]) -> Bool {
    guard let node else { return false }
    if node.id == id {
      result.append(node)
      return true
    }
    for child in node.children {
      if ancestry(id, in: child, into: &result) {
        result.append(node)
        return true
      }
    }
    return false
  }

  /// Platform-neutral input dispatch. Coordinates are logical points in the root.
  @discardableResult public func input(
    id: NodeID? = nil, event: Int, point: CGPoint = .zero, value: Int = 0,
    modifiers: EventModifiers = [], text: String = "", updatesPressedState: Bool = false
  ) -> Bool {
    transactionDepth += 1
    defer { finishTransaction() }
    if event == 7 {
      if let id { find(id, in: tree)?.textAction?(text) }
      return true
    }
    var chain: [Element] = []
    if let id, id.rawValue != 0 {
      _ = ancestry(id, in: tree, into: &chain)
    } else if let root = tree {
      chain = hitChain(root, point: point, hover: event == 1 || event == 10)
    }
    if event == 1 || event == 10 {
      hoverPending = true
      hoverPoint = event == 10 ? nil : point
    }
    if event == 2,
      let scroll = chain.first(where: { $0.kind == .scroll && $0.props.showsScrollIndicators }),
      let content = scroll.children.first,
      point.x >= scroll.frame.maxX - 12 && content.frame.height > scroll.frame.height
    {
      scrollDrag = (
        scroll.id, point, scroll.props.scrollOffset, content.frame.height / scroll.frame.height
      )
      return true
    }
    if event == 1 || event == 3, let drag = scrollDrag {
      if let node = find(drag.id, in: tree) {
        scroll(
          node,
          to: Point(
            x: drag.offset.x,
            y: drag.offset.y + (point.y - drag.start.y) * drag.ratio))
      }
      if event == 3 { scrollDrag = nil }
      return true
    }
    if event == 2 {
      pointerDown = chain.first(where: { $0.action != nil })?.id
      if updatesPressedState, let pointerDown { interact(pointerDown, .pressed(true)) }
      if let node = chain.first(where: { $0.dragAction != nil }) {
        dragging = (node.id, point, CGPoint(x: node.frame.minX, y: node.frame.minY))
      }
      if let node = chain.first(where: { $0.props.focusable || $0.focusAction != nil }) {
        focused = node.id
        interact(node.id, .focus(true))
      }
    }
    if event == 3, updatesPressedState, let pointerDown {
      interact(pointerDown, .pressed(false))
    }
    if event == 1 || event == 2 || event == 3, let drag = dragging {
      let location = CGPoint(x: point.x - drag.origin.x, y: point.y - drag.origin.y)
      let start = CGPoint(x: drag.start.x - drag.origin.x, y: drag.start.y - drag.origin.y)
      find(drag.id, in: tree)?.dragAction?(
        DragGesture.Value(
          location: location, startLocation: start,
          translation: CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y),
          time: Date()), event == 3)
      if event == 3 {
        dragging = nil
        pointerDown = nil
      }
      return true
    }
    if event == 3 {
      defer { pointerDown = nil }
      if let down = pointerDown, chain.contains(where: { $0.id == down }) {
        performTap(down)
        return true
      }
    }
    if event == 9, let node = chain.first(where: { $0.secondaryAction != nil }) {
      node.secondaryAction?(CGPoint(x: point.x - node.frame.minX, y: point.y - node.frame.minY))
      return true
    }
    if event == 4, let node = chain.first(where: { $0.doubleTapAction != nil }) {
      node.doubleTapAction?()
      return true
    }
    if event == 5, let node = chain.first(where: { $0.scrollAction != nil }) {
      var offset = unpublishedOffsets[node.id] ?? node.props.scrollOffset
      if modifiers.contains(.shift) || !node.props.scrollAxes.contains(.vertical) {
        offset.x -= Double(value) * 0.4
      } else {
        offset.y -= Double(value) * 0.4
      }
      if let content = node.children.first {
        offset.x = max(0, min(offset.x, content.frame.width - node.frame.width))
        offset.y = max(0, min(offset.y, content.frame.height - node.frame.height))
      }
      if offset != (unpublishedOffsets[node.id] ?? node.props.scrollOffset) {
        hoverPending = true
        hoverPoint = backend.pointerLocation(fallback: point)
        scroll(node, to: offset)
      }
      return true
    }
    if event == 6 {
      let special: [Int: KeyEquivalent] = [
        8: .delete, 9: .tab, 13: .return, 27: .escape, 32: .space, 33: .pageUp, 34: .pageDown,
        35: .end, 36: .home, 37: .leftArrow, 38: .upArrow, 39: .rightArrow, 40: .downArrow,
        46: .deleteForward,
      ]
      let characters = UnicodeScalar(value).map { String($0).lowercased() } ?? ""
      let key = special[value] ?? KeyEquivalent(characters.first ?? " ")
      let press = KeyPress(key: key, characters: characters, modifiers: modifiers)
      if let focus = (id?.rawValue ?? 0) != 0 ? id : focused {
        chain = []
        _ = ancestry(focus, in: tree, into: &chain)
      }
      for node in chain { if node.keyAction?(press) == .handled { return true } }
      if key == .return, let node = chain.first(where: { $0.submitAction != nil }) {
        node.submitAction?()
        return true
      }
      func shortcut(_ node: Element) -> Bool {
        if let shortcut = node.props.keyboardShortcut, shortcut.key == key,
          shortcut.modifiers == modifiers
            || (shortcut.modifiers == .command && modifiers == .control),
          node.props.enabled && node.props.hitTesting
        {
          node.action?()
          return true
        }
        return node.children.contains(where: shortcut)
      }
      if let tree, shortcut(tree) { return true }
    }
    return false
  }
  private func hitChain(
    _ node: Element, point: CGPoint,
    hover: Bool = false
  ) -> [Element] {
    guard node.props.visible, node.props.hitTesting, node.props.enabled else { return [] }
    let inside =
      point.x >= node.frame.minX && point.x < node.frame.minX + node.frame.width
      && point.y >= node.frame.minY && point.y < node.frame.minY + node.frame.height
    if node.props.clipped && !inside { return [] }
    var children =
      node.kind == .layer && node.props.layerBehind
      ? Array(node.children.reversed()) : node.children
    if children.count > 1 && children.contains(where: { $0.props.zIndex != 0 }) {
      children = children.enumerated().sorted {
        $0.element.props.zIndex == $1.element.props.zIndex
          ? $0.offset < $1.offset : $0.element.props.zIndex < $1.element.props.zIndex
      }.map { $0.element }
    }
    var childPoint = point
    if let offset = unpublishedOffsets[node.id] {
      childPoint.x += offset.x - node.props.scrollOffset.x
      childPoint.y += offset.y - node.props.scrollOffset.y
    }
    for child in children.reversed() {
      let result = hitChain(child, point: childPoint, hover: hover)
      if !result.isEmpty { return result + [node] }
    }
    // Layout-only containers, especially an empty overlay, do not occlude
    // interactive content underneath them.
    let interactive =
      node.action != nil || node.dragAction != nil || node.scrollAction != nil
      || node.secondaryAction != nil || node.doubleTapAction != nil || node.hoverAction != nil
      || node.focusAction != nil || node.props.focusable
    let painted: Bool
    switch node.kind {
    case .text, .shape, .path, .image, .gradient, .button, .styledButton, .textField: painted = true
    default: painted = (node.props.background?.opacity ?? 0) > 0
    }
    // Decorative canvas ink (a card's stroked overlay, for example) has no
    // native input window. It must not hide the hover target below it.
    return inside && (interactive || (!hover && painted)) ? [node] : []
  }

  // MARK: - Internals

  private func scroll(_ node: Element, to requested: Point) {
    var offset = requested
    if let content = node.children.first {
      offset.x = max(0, min(offset.x, content.frame.width - node.frame.width))
      offset.y = max(0, min(offset.y, content.frame.height - node.frame.height))
    }
    guard offset != (unpublishedOffsets[node.id] ?? node.props.scrollOffset) else { return }
    unpublishedOffsets[node.id] = offset
    // Global/named geometry and active presentations require a full pass.
    // Opaque layouts must reproduce exactly translated placement proposals.
    let translates = node.children.allSatisfy {
      layoutEngine.canTranslateScroll(
        $0, dx: node.props.scrollOffset.x - offset.x,
        dy: node.props.scrollOffset.y - offset.y)
    }
    if !needsRender || pendingScroll?.id == node.id, !isRendering, let key = node.scrollStateKey,
      translates, mounted?.hasActivePresentation == false
    {
      pendingScroll = (node.id, key, offset)
    } else {
      pendingScroll = nil
    }
    node.scrollAction?(offset)
  }

  private func updateScroll() -> Bool {
    guard let pending = pendingScroll, var updated = mounted else { return false }
    pendingScroll = nil
    var commands: [RenderCommand]? = backend.needsRenderCommands ? [] : nil
    let started = Date.timeIntervalSinceReferenceDate
    func translate(
      _ node: inout Element, dx: Double, dy: Double,
      origins: [AnyHashable: CGPoint]
    ) {
      node.reusesLayout = false
      node.frame.origin.x += dx
      node.frame.origin.y += dy
      node.customLayoutFrames = node.customLayoutFrames.map { $0.offsetBy(dx: dx, dy: dy) }
      node.layoutContext = origins
      var childOrigins = origins
      if let name = node.props.coordinateSpace {
        childOrigins[name] = CGPoint(x: node.frame.minX, y: node.frame.minY)
      }
      if let snapshot = node.geometrySnapshot {
        snapshot.rect.origin = CGPoint(x: node.frame.minX, y: node.frame.minY)
        snapshot.namedOrigins = childOrigins
      }
      commands?.append(.setFrame(id: node.id, frame: node.frame))
      for i in node.children.indices {
        translate(&node.children[i], dx: dx, dy: dy, origins: childOrigins)
      }
    }
    func move(_ node: inout Element) -> Bool {
      if node.id == pending.id {
        let old = node.props.scrollOffset
        node.props.scrollOffset = pending.offset
        node.reusesLayout = false
        commands?.append(.setProps(id: node.id, props: node.props))
        var origins = node.layoutContext
        if let name = node.props.coordinateSpace {
          origins[name] = CGPoint(x: node.frame.minX, y: node.frame.minY)
        }
        for i in node.children.indices {
          translate(
            &node.children[i], dx: old.x - pending.offset.x,
            dy: old.y - pending.offset.y, origins: origins)
        }
        return true
      }
      for i in node.children.indices {
        if move(&node.children[i]) {
          node.reusesLayout = false
          return true
        }
      }
      return false
    }
    guard move(&updated) else { return false }
    pendingAnimation = nil
    isRendering = true
    mounted = updated
    tree = updated
    lastCommands = commands ?? []
    lastTimings = ["scroll.translate": (Date.timeIntervalSinceReferenceDate - started) * 1000]
    let published = Date.timeIntervalSinceReferenceDate
    if let commands { backend.perform(commands) }
    backend.didScroll(updated)
    lastTimings["backend"] = (Date.timeIntervalSinceReferenceDate - published) * 1000
    isRendering = false
    return true
  }

  private func buildTree() -> Element {
    lastTimings.removeAll(keepingCapacity: true)
    var start = Date.timeIntervalSinceReferenceDate
    StateRegistry.shared.begin()
    LifecycleRegistry.shared.begin()
    var element = evaluations.evaluateRoot { _render(root, path: rootPath) }
    lastTimings["evaluate"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    start = Date.timeIntervalSinceReferenceDate
    element = normalize(element, previous: normalized)
    normalized = element
    if let animation = pendingAnimation ?? AnimationContext.current {
      element.props.animation = animation
    }
    pendingAnimation = nil
    resolveEnvironment(&element, previous: mounted)
    lastTimings["environment"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    start = Date.timeIntervalSinceReferenceDate
    layoutEngine.layout(root: &element, in: contentSize)
    lastTimings["layout"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    for (key, value) in layoutEngine.lastTimings { lastTimings["layout." + key] = value }
    start = Date.timeIntervalSinceReferenceDate
    element = resolvePresentations(element, in: contentSize)
    assignKeys(&element)
    StateRegistry.shared.end()
    _ = resolvePreferences(element)
    lastTimings["finalize"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    return element
  }

  private func update() {
    if updateScroll() { return }
    guard let old = mounted else {
      mount()
      return
    }

    isRendering = true
    let newTree = buildTree()
    var start = Date.timeIntervalSinceReferenceDate
    var commands: [RenderCommand]? = backend.needsRenderCommands ? [] : nil
    let mountedTree = diffElement(
      old: old,
      new: newTree,
      parent: nil,
      index: 0,
      commands: &commands,
      allocator: &allocator
    )
    mounted = mountedTree
    tree = mountedTree
    rebuildActions(from: mountedTree)
    lastCommands = commands ?? []
    lastTimings["diff"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    start = Date.timeIntervalSinceReferenceDate
    if let commands { backend.perform(commands) }
    backend.didRender(mountedTree)
    lastTimings["backend"] = (Date.timeIntervalSinceReferenceDate - start) * 1000
    LifecycleRegistry.shared.commit()
    isRendering = false
  }
  private func rebuildActions(from element: Element) {
    var hovered: [NodeID: (Bool) -> Void] = [:]
    func collect(_ node: Element) {
      if let action = node.hoverAction { hovered[node.id] = action }
      node.children.forEach(collect)
    }
    collect(element)
    hoverActions = hovered
  }
}
