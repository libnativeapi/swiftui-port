/// Allocates a fresh ``NodeID`` for a newly created element.

/// Emits the commands that build a brand-new subtree.

/// Reconciles one old/new pair and returns the mounted new element.

/// Reconciles a sibling list, emitting one remove per vanished subtree, one
/// move per reordered key, and a create/insert only for genuinely new keys.
struct NodeIDAllocator {
  private var next = 1

  mutating func allocate() -> NodeID {
    defer { next += 1 }
    return NodeID(rawValue: next)
  }
}
func createSubtree(
  _ element: Element,
  parent: NodeID?,
  index: Int,
  commands: inout [RenderCommand],
  allocator: inout NodeIDAllocator
) -> Element {
  var result = element
  result.id = allocator.allocate()

  commands.append(.create(id: result.id, kind: result.kind, props: result.props))
  commands.append(.insert(id: result.id, parent: parent, index: index))
  commands.append(.setFrame(id: result.id, frame: result.frame))

  for childIndex in result.children.indices {
    result.children[childIndex] = createSubtree(
      result.children[childIndex],
      parent: result.id,
      index: childIndex,
      commands: &commands,
      allocator: &allocator
    )
  }
  return result
}
func diffElement(
  old: Element?,
  new: Element,
  parent: NodeID?,
  index: Int,
  commands: inout [RenderCommand],
  allocator: inout NodeIDAllocator
) -> Element {
  guard let old, old.key == new.key else {
    return createSubtree(
      new,
      parent: parent,
      index: index,
      commands: &commands,
      allocator: &allocator
    )
  }

  // Same key, different kind: the native control cannot be reused. Replace it
  // in place rather than trying to mutate one control into another.
  guard old.kind == new.kind else {
    commands.append(.remove(id: old.id))
    return createSubtree(
      new,
      parent: parent,
      index: index,
      commands: &commands,
      allocator: &allocator
    )
  }
  if new.reusesLayout && old.id == new.id && old.frame == new.frame { return new }

  var result = new
  result.id = old.id

  if old.props != new.props {
    commands.append(.setProps(id: old.id, props: new.props))
  }
  if old.frame != new.frame {
    commands.append(.setFrame(id: old.id, frame: new.frame))
  }

  result.children = diffChildren(
    old: old.children,
    new: new.children,
    parent: old.id,
    commands: &commands,
    allocator: &allocator
  )
  return result
}
func diffChildren(
  old: [Element],
  new: [Element],
  parent: NodeID,
  commands: inout [RenderCommand],
  allocator: inout NodeIDAllocator
) -> [Element] {
  // State/style changes normally preserve the sibling order. Avoid building
  // key dictionaries and scanning a move list for every wrapper in that case.
  if old.count == new.count && zip(old, new).allSatisfy({ $0.key == $1.key }) {
    return new.indices.map { index in
      diffElement(
        old: old[index], new: new[index], parent: parent, index: index,
        commands: &commands, allocator: &allocator)
    }
  }
  var oldByKey: [ElementKey: Element] = [:]
  for child in old where oldByKey[child.key] == nil {
    oldByKey[child.key] = child
  }
  let newKeys = Set(new.map(\.key))

  // Remove old-only children first so subsequent indices refer to the list the
  // backend will have when the moves/inserts run.
  for child in old.reversed() where !newKeys.contains(child.key) {
    commands.append(.remove(id: child.id))
  }

  var live = old.filter { newKeys.contains($0.key) }.map(\.key)
  var result: [Element] = []
  result.reserveCapacity(new.count)

  for (index, child) in new.enumerated() {
    if let oldChild = oldByKey[child.key] {
      let position = live.firstIndex(of: child.key) ?? index
      let kindChanged = oldChild.kind != child.kind
      if !kindChanged && position != index {
        commands.append(.move(id: oldChild.id, parent: parent, index: index))
        live.remove(at: position)
        live.insert(child.key, at: index)
      }
      let reconciled = diffElement(
        old: oldChild,
        new: child,
        parent: parent,
        index: index,
        commands: &commands,
        allocator: &allocator
      )
      if kindChanged {
        if let current = live.firstIndex(of: child.key) {
          live.remove(at: current)
        }
        live.insert(child.key, at: min(index, live.count))
      }
      result.append(reconciled)
    } else {
      let created = createSubtree(
        child,
        parent: parent,
        index: index,
        commands: &commands,
        allocator: &allocator
      )
      live.insert(child.key, at: min(index, live.count))
      result.append(created)
    }
  }
  return result
}
