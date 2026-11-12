import Foundation

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
public final class Renderer {
  public let backend: any RenderBackend
  public let layoutEngine: LayoutEngine

  private let root: AnyView
  private var allocator = NodeIDAllocator()
  private var mounted: Element?
  private var actions: [NodeID: () -> Void] = [:]
  private var isRendering = false
  private var needsRender = false
  private var contentSize: Size

  /// The last mounted element tree, with frames from the reference layout.
  public private(set) var tree: Element?
  /// The commands produced by the most recent render pass.
  public private(set) var lastCommands: [RenderCommand] = []

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
      self?.setNeedsRender()
    }
    backend.tapHandler = { [weak self] id in
      self?.performTap(id)
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
    var commands: [RenderCommand] = []
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
    lastCommands = commands
    isRendering = false

    backend.perform(commands)

    if needsRender {
      renderIfNeeded()
    }
  }

  /// Updates the available content area and re-renders if it changed.
  public func resize(to size: Size) {
    guard size != contentSize else { return }
    contentSize = size
    setNeedsRender()
  }

  /// Marks the tree dirty and renders now unless already inside a render pass.
  public func setNeedsRender() {
    if isRendering {
      needsRender = true
      return
    }
    renderIfNeeded()
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
      passes += 1
    } while needsRender && passes < 8
  }

  /// Invokes the current action registered for a native button.
  public func performTap(_ id: NodeID) {
    actions[id]?()
  }

  // MARK: - Internals

  private func buildTree() -> Element {
    var element = normalize(_render(root, path: []))
    resolveEnvironment(&element)
    assignKeys(&element, parent: .root, index: 0)
    layoutEngine.layout(root: &element, in: contentSize)
    return element
  }

  private func update() {
    guard let old = mounted else {
      mount()
      return
    }

    isRendering = true
    let newTree = buildTree()
    var commands: [RenderCommand] = []
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
    lastCommands = commands
    isRendering = false

    backend.perform(commands)
  }

  private func rebuildActions(from element: Element) {
    var collected: [NodeID: () -> Void] = [:]
    collectActions(element, into: &collected)
    actions = collected
  }
}
