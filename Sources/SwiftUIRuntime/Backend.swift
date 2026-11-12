/// One operation the runtime asks a backend to perform.
///
/// A render pass produces a minimal ordered list: removals first, then the
/// creates/inserts/moves needed to reach the new child order, then property
/// updates, then frame changes. A matched element is never recreated just
/// because its properties changed.
public enum RenderCommand: Equatable {
  case create(id: NodeID, kind: ElementKind, props: NodeProps)
  case insert(id: NodeID, parent: NodeID?, index: Int)
  case remove(id: NodeID)
  case move(id: NodeID, parent: NodeID?, index: Int)
  case setProps(id: NodeID, props: NodeProps)
  case setFrame(id: NodeID, frame: Rect)
}

/// The platform seam.
///
/// `SwiftUIRuntime` never imports nativeapi. A backend receives commands and
/// turns them into real view operations; ``FakeBackend`` records them for
/// tests.
public protocol RenderBackend: AnyObject {
  func perform(_ commands: [RenderCommand])

  /// Called by the backend when a native button is clicked. The renderer wires
  /// this to the current action for that node.
  var tapHandler: ((NodeID) -> Void)? { get set }
}

/// A backend that records commands instead of touching a platform toolkit.
///
/// This is the only backend needed to test the engine on macOS, where the
/// `SwiftUI` and `SwiftUIPort` modules are not built.
public final class FakeBackend: RenderBackend {
  public private(set) var commands: [RenderCommand] = []
  public var tapHandler: ((NodeID) -> Void)?

  public init() {}

  public func perform(_ commands: [RenderCommand]) {
    self.commands.append(contentsOf: commands)
  }

  /// Clears the recorded commands, keeping the fake's state empty.
  public func reset() {
    commands.removeAll()
  }

  /// Simulates a click on a button node.
  public func tap(_ id: NodeID) {
    tapHandler?(id)
  }

  public var createdIDs: [NodeID] {
    commands.compactMap {
      if case .create(let id, _, _) = $0 { return id }
      return nil
    }
  }

  public var removedIDs: [NodeID] {
    commands.compactMap {
      if case .remove(let id) = $0 { return id }
      return nil
    }
  }

  public var updatedIDs: [NodeID] {
    commands.compactMap {
      if case .setProps(let id, _) = $0 { return id }
      return nil
    }
  }
}
