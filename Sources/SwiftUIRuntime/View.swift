/// A view that describes part of the user interface.
///
/// This mirrors the shape of SwiftUI's `View` protocol: a value type with a
/// `body` built from other views. The engine evaluates a view by walking
/// `body` until it reaches a primitive view (``Text``, ``Button``, a stack,
/// etc.), then turns the result into an ``Element`` tree.

/// A view the engine knows how to turn into an element directly. Not public:
/// users compose ``View`` values and never implement this.

/// Evaluates `view` and its `body` chain down to a primitive element.
///
/// The path is the structural position used for `@State` storage scopes; it is
/// distinct from the diff identity, which also honours `.id(_:)`.

/// A type-erased view.
///
/// `AnyView` is mostly an escape hatch for code that needs to store or return
/// differently typed views. It hides the concrete type from the diff's kind
/// comparison, so prefer concrete views and generic containers.

// `Never` is the `Body` of every primitive view. It has no values, so the body
// getter can never run; the conformance exists so the associated type is valid.
@MainActor @preconcurrency public protocol View {
  associatedtype Body: View

  @ViewBuilder var body: Body { get }
}
protocol _PrimitiveView: View {
  func _makeElement(path: [Int]) -> Element
}
@MainActor func _render<V: View>(_ view: V, path: [Int]) -> Element {
  if let graph = EvaluationGraph.active {
    return graph.evaluate(type: ObjectIdentifier(V.self), path: path) {
      _renderUncached(view, path: path)
    }
  }
  return _renderUncached(view, path: path)
}
@MainActor private func _renderUncached<V: View>(_ view: V, path: [Int]) -> Element {
  _installState(view, path: path)
  if let primitive = view as? any _PrimitiveView {
    return primitive._makeElement(path: path)
  }
  let body = StateRegistry.shared.withScope(path) { view.body }
  return _render(body, path: path)
}
@MainActor private var staticViewTypes = Set<ObjectIdentifier>()
@MainActor func _installState<V>(_ value: V, path: [Int]) {
  let type = ObjectIdentifier(V.self)
  if staticViewTypes.contains(type) { return }
  let mirror = Mirror(reflecting: value)
  var dynamic = false
  for (index, child) in mirror.children.enumerated() {
    dynamic =
      dynamic || child.value is any _EnvironmentProperty || child.value is any _StateProperty
    (child.value as? any _EnvironmentProperty)?.installEnvironment()
    (child.value as? any _StateProperty)?.install(
      StateKey(path: path, owner: ObjectIdentifier(V.self), property: index))
  }
  // Enum payloads and class subclasses can change their reflected field types.
  if !dynamic && mirror.displayStyle == .struct { staticViewTypes.insert(type) }
}
public struct AnyView: View {
  public typealias Body = Never

  private let builder: ([Int]) -> Element

  public init<V: View>(_ view: V) {
    self.builder = { path in _render(view, path: path) }
  }

  public var body: Never { fatalError("AnyView renders its erased view") }
}
extension AnyView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    builder(path)
  }
}
extension Never: View {
  public typealias Body = Never
  public var body: Never { return fatalError("Never has no body") }
}
