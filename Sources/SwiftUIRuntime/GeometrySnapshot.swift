import Foundation

/// Registrations belonging to content evaluated during layout. Retaining a
/// geometry subtree must retain its state/tasks without replaying appearances.
final class GeometrySnapshot {
  static var active: GeometrySnapshot?
  var state = Set<StateKey>()
  var lifecycle = Set<StateKey>()
  var dependsOnPosition = false
  var rect: CGRect
  var namedOrigins: [AnyHashable: CGPoint]
  init(rect: CGRect, namedOrigins: [AnyHashable: CGPoint]) {
    self.rect = rect
    self.namedOrigins = namedOrigins
  }
  func retain() {
    StateRegistry.shared.retain(state)
    LifecycleRegistry.shared.retain(lifecycle)
  }
  func capture<T>(_ body: () -> T) -> T {
    let previous = Self.active
    Self.active = self
    defer {
      Self.active = previous
      previous?.state.formUnion(state)
      previous?.lifecycle.formUnion(lifecycle)
      if dependsOnPosition { previous?.dependsOnPosition = true }
    }
    return body()
  }
}
