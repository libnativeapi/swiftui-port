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
  commands: inout [RenderCommand]?,
  allocator: inout NodeIDAllocator
) -> Element {
  var result = element
  mountSubtree(&result, parent: parent, index: index, commands: &commands, allocator: &allocator)
  return result
}

func mountSubtree(
  _ element: inout Element, parent: NodeID?, index: Int,
  commands: inout [RenderCommand]?, allocator: inout NodeIDAllocator
) {
  let id = allocator.allocate()
  element.id = id

  commands?.append(.create(id: id, kind: element.kind, props: element.props))
  commands?.append(.insert(id: id, parent: parent, index: index))
  commands?.append(.setFrame(id: id, frame: element.frame))

  for childIndex in element.children.indices {
    mountSubtree(
      &element.children[childIndex],
      parent: id,
      index: childIndex,
      commands: &commands,
      allocator: &allocator
    )
  }
}
func diffElement(
  old: Element?,
  new: Element,
  parent: NodeID?,
  index: Int,
  commands: inout [RenderCommand]?,
  allocator: inout NodeIDAllocator
) -> Element {
  var result = new
  reconcile(old: old, new: &result, parent: parent, index: index, commands: &commands,
            allocator: &allocator)
  return result
}

func reconcile(
  old: Element?, new: inout Element, parent: NodeID?, index: Int,
  commands: inout [RenderCommand]?, allocator: inout NodeIDAllocator
) {
  guard let old, old.key == new.key else {
    mountSubtree(
      &new,
      parent: parent,
      index: index,
      commands: &commands,
      allocator: &allocator
    )
    return
  }

  // Same key, different kind: the native control cannot be reused. Replace it
  // in place rather than trying to mutate one control into another.
  guard old.kind == new.kind else {
    commands?.append(.remove(id: old.id))
    mountSubtree(
      &new,
      parent: parent,
      index: index,
      commands: &commands,
      allocator: &allocator
    )
    return
  }
  if new.reusesLayout && old.id == new.id && old.frame == new.frame { return }
  new.id = old.id

  if commands != nil, old.props != new.props {
    commands?.append(.setProps(id: old.id, props: new.props))
  }
  if commands != nil, old.frame != new.frame {
    commands?.append(.setFrame(id: old.id, frame: new.frame))
  }

  if old.children.count == new.children.count
    && zip(old.children, new.children).allSatisfy({ $0.key == $1.key })
  {
    for i in new.children.indices {
      reconcile(old: old.children[i], new: &new.children[i], parent: old.id, index: i,
                commands: &commands, allocator: &allocator)
    }
  } else {
    new.children = diffChildren(
      old: old.children, new: new.children, parent: old.id, commands: &commands,
      allocator: &allocator)
  }
}
private func diffChildren(
  old: [Element],
  new: [Element],
  parent: NodeID,
  commands: inout [RenderCommand]?,
  allocator: inout NodeIDAllocator
) -> [Element] {
  var oldByKey: [ElementKey: Element] = [:]
  for child in old where oldByKey[child.key] == nil {
    oldByKey[child.key] = child
  }
  var live: [ElementKey]?
  if commands != nil {
    let newKeys = Set(new.map(\.key))
    // Remove old-only children before calculating moves and insertions.
    for child in old.reversed() where !newKeys.contains(child.key) {
      commands?.append(.remove(id: child.id))
    }
    live = old.filter { newKeys.contains($0.key) }.map(\.key)
  }
  var result: [Element] = []
  result.reserveCapacity(new.count)

  for (index, child) in new.enumerated() {
    if let oldChild = oldByKey[child.key] {
      let position = live?.firstIndex(of: child.key) ?? index
      let kindChanged = oldChild.kind != child.kind
      if !kindChanged && position != index {
        commands?.append(.move(id: oldChild.id, parent: parent, index: index))
        live?.remove(at: position)
        live?.insert(child.key, at: index)
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
        if let current = live?.firstIndex(of: child.key) {
          live?.remove(at: current)
        }
        if let count = live?.count { live?.insert(child.key, at: min(index, count)) }
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
      if let count = live?.count { live?.insert(child.key, at: min(index, count)) }
      result.append(created)
    }
  }
  return result
}
