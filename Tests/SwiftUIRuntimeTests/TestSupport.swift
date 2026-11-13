/// Evaluates a view exactly the way the renderer's build pass does.
@testable import SwiftUIRuntime

/// Mounts `old` and diffs `new` against it, returning the mounted new tree and
/// the commands the backend would receive.

@MainActor @preconcurrency
func makeTree<V: View>(_ view: V, size: Size) -> Element {
  var element = normalize(_render(view, path: ViewPath()))
  resolveEnvironment(&element)
  assignKeys(&element)
  LayoutEngine().layout(root: &element, in: size)
  return element
}
@MainActor @preconcurrency
func diffTrees<V1: View, V2: View>(
  old: V1,
  new: V2,
  size: Size
) -> (mounted: Element, updated: Element, commands: [RenderCommand]) {
  var allocator = NodeIDAllocator()
  var commands: [RenderCommand]? = []
  let mounted = createSubtree(
    makeTree(old, size: size),
    parent: nil,
    index: 0,
    commands: &commands,
    allocator: &allocator
  )
  commands = []
  let updated = diffElement(
    old: mounted,
    new: makeTree(new, size: size),
    parent: nil,
    index: 0,
    commands: &commands,
    allocator: &allocator
  )
  return (mounted, updated, commands ?? [])
}
func findNode(in element: Element, kind: ElementKind) -> Element? {
  if element.kind == kind { return element }
  for child in element.children {
    if let match = findNode(in: child, kind: kind) { return match }
  }
  return nil
}
func findNode(in element: Element, text: String) -> Element? {
  if element.props.text == text { return element }
  for child in element.children {
    if let match = findNode(in: child, text: text) { return match }
  }
  return nil
}
func allNodes(_ element: Element) -> [Element] {
  [element] + element.children.flatMap(allNodes)
}
func count(_ commands: [RenderCommand], where predicate: (RenderCommand) -> Bool) -> Int {
  commands.filter(predicate).count
}
extension RenderCommand {
  var isCreate: Bool {
    if case .create = self { return true }
    return false
  }

  var isRemove: Bool {
    if case .remove = self { return true }
    return false
  }

  var isMove: Bool {
    if case .move = self { return true }
    return false
  }

  var isInsert: Bool {
    if case .insert = self { return true }
    return false
  }

  var isSetProps: Bool {
    if case .setProps = self { return true }
    return false
  }

  var isSetFrame: Bool {
    if case .setFrame = self { return true }
    return false
  }
}
