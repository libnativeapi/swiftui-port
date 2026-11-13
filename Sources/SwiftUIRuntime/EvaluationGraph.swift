/// Tracks state reads while evaluating bodies. A local state write invalidates
/// its readers and their ancestors; unrelated branches retain their raw element
/// trees, state slots and lifecycle registrations. Unknown notifications (for
/// example ObservableObject) conservatively invalidate the whole graph.
final class EvaluationGraph {
  static var active: EvaluationGraph?
  private static var nextID = 1
  private final class Node {
    let type: ObjectIdentifier
    let path: ViewPath
    let id: Int
    var revision = 0
    weak var parent: Node?
    weak var graph: EvaluationGraph?
    var children: [Node] = []
    var cursor = 0
    var dirty = true, descendantDirty = true, forceChildren = true
    var inputChanged = true
    var result: Element?
    var reads = Set<StateKey>()
    var previousReads = Set<StateKey>()
    var state = Set<StateKey>()
    var lifecycle = Set<StateKey>()
    lazy var reference = WeakNode(self)
    init(type: ObjectIdentifier, path: ViewPath, parent: Node?, graph: EvaluationGraph) {
      self.type = type
      self.path = path
      self.parent = parent
      self.graph = graph
      id = EvaluationGraph.nextID
      EvaluationGraph.nextID += 1
    }
    deinit {
      for key in reads {
        graph?.removeReader(id, of: key)
      }
    }
    func retain() {
      if !state.isEmpty { StateRegistry.shared.retain(state) }
      if !lifecycle.isEmpty { LifecycleRegistry.shared.retain(lifecycle) }
      children.forEach { $0.retain() }
    }
  }
  private final class WeakNode {
    weak var value: Node?
    init(_ value: Node) { self.value = value }
  }
  private var root: Node?
  private var current: Node?
  private var readers: [StateKey: [Int: WeakNode]] = [:]

  private func removeReader(_ id: Int, of key: StateKey) {
    readers[key]?.removeValue(forKey: id)
    if readers[key]?.isEmpty == true { readers.removeValue(forKey: key) }
  }

  func invalidateAll() {
    root?.dirty = true
    root?.descendantDirty = true
  }

  func invalidate(_ key: StateKey) {
    // Layout-built content can read state outside this graph.
    guard let entries = readers[key], entries.values.contains(where: { $0.value != nil }) else {
      invalidateAll()
      return
    }
    for entry in entries.values {
      guard let node = entry.value else { continue }
      node.dirty = true
      var ancestor: Node? = node
      while let item = ancestor {
        if item.descendantDirty { break }
        item.descendantDirty = true
        ancestor = item.parent
      }
    }
  }
  func read(_ key: StateKey) {
    guard let current, current.reads.insert(key).inserted,
      !current.previousReads.contains(key)
    else { return }
    readers[key, default: [:]][current.id] = current.reference
  }
  func installState(_ key: StateKey) { current?.state.insert(key) }
  func installLifecycle(_ key: StateKey) { current?.lifecycle.insert(key) }
  /// A primitive's stored content is unchanged by its own internal state (for
  /// example a ScrollView offset). An ancestor supplying new input still wins.
  func withStoredContent(_ body: () -> Element) -> Element {
    guard let current, !current.inputChanged else { return body() }
    let previous = current.forceChildren
    current.forceChildren = false
    defer { current.forceChildren = previous }
    return body()
  }

  func evaluateRoot(_ body: () -> Element) -> Element {
    let previous = Self.active
    Self.active = self
    defer { Self.active = previous }
    return body()
  }
  func evaluate(type: ObjectIdentifier, path: ViewPath, _ body: () -> Element) -> Element {
    let parent = current
    let node: Node
    if let parent {
      let index = parent.cursor
      parent.cursor += 1
      if index < parent.children.count,
        parent.children[index].type == type && parent.children[index].path == path
      {
        node = parent.children[index]
      } else {
        node = Node(type: type, path: path, parent: parent, graph: self)
        if index < parent.children.count {
          parent.children[index] = node
        } else {
          parent.children.append(node)
        }
      }
    } else if let root, root.type == type, root.path == path {
      node = root
    } else {
      node = Node(type: type, path: path, parent: nil, graph: self)
      root = node
    }
    let forced = parent?.forceChildren ?? false
    if !forced && !node.descendantDirty, let result = node.result {
      node.retain()
      return result
    }
    swap(&node.reads, &node.previousReads)
    node.reads.removeAll(keepingCapacity: true)
    node.state.removeAll(keepingCapacity: true)
    node.lifecycle.removeAll(keepingCapacity: true)
    node.forceChildren = forced || node.dirty
    node.inputChanged = forced || node.result == nil
    node.cursor = 0
    current = node
    var result = body()
    for key in node.previousReads where !node.reads.contains(key) { removeReader(node.id, of: key) }
    result.evaluationID = node.id
    node.revision += 1
    result.evaluationRevision = node.revision
    current = parent
    if node.cursor < node.children.count {
      node.children.removeLast(node.children.count - node.cursor)
    }
    node.result = result
    node.dirty = false
    node.descendantDirty = false
    return result
  }
}
