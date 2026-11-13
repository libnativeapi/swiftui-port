/// One operation the runtime asks a backend to perform.

///
/// A render pass produces a minimal ordered list: removals first, then the
/// creates/inserts/moves needed to reach the new child order, then property
/// updates, then frame changes. A matched element is never recreated just
/// because its properties changed.

/// The platform seam.
///
/// `SwiftUIRuntime` never imports nativeapi. A backend receives commands and
/// turns them into real view operations; ``FakeBackend`` records them for
/// tests.

/// A backend that records commands instead of touching a platform toolkit.
///
/// This is the only backend needed to test the engine on macOS, where the
/// `SwiftUI` and `SwiftUIPort` modules are not built.

import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public enum RenderCommand: Equatable {
  case create(id: NodeID, kind: ElementKind, props: NodeProps)
  case insert(id: NodeID, parent: NodeID?, index: Int)
  case remove(id: NodeID)
  case move(id: NodeID, parent: NodeID?, index: Int)
  case setProps(id: NodeID, props: NodeProps)
  case setFrame(id: NodeID, frame: Rect)
}
public protocol RenderBackend: AnyObject {
  /// Return true when the backend will call this on its next update boundary.
  func requestRender(_ render: @escaping () -> Void) -> Bool
  /// Optional diagnostics, after a complete runtime update (milliseconds).
  func didMeasureRender(_ timings: [String: Double])
  func perform(_ commands: [RenderCommand])
  func didRender(_ root: Element)
  /// Content and actions are unchanged; only a scroll offset and descendant
  /// frames moved. Backends may retain animation/control property state.
  func didScroll(_ root: Element)
  /// Current pointer in root coordinates, or nil when it is outside/occluded.
  /// Headless backends use the supplied input point.
  func pointerLocation(fallback: CGPoint) -> CGPoint?

  /// Called by the backend when a native button is clicked. The renderer wires
  /// this to the current action for that node.
  var tapHandler: ((NodeID) -> Void)? { get set }
  /// Groups native notifications from one message turn into one render.
  var transactionHandler: ((() -> Void) -> Void)? { get set }
}
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
extension RenderBackend {
  public func requestRender(_ render: @escaping () -> Void) -> Bool { false }
  public func didMeasureRender(_ timings: [String: Double]) {}
  public func didRender(_ root: Element) {}
  public func didScroll(_ root: Element) { didRender(root) }
  public func pointerLocation(fallback: CGPoint) -> CGPoint? { fallback }
  public var transactionHandler: ((() -> Void) -> Void)? {
    get { nil }
    set {}
  }
}
