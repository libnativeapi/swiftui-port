/// A view that describes part of the user interface.
///
/// This mirrors the shape of SwiftUI's `View` protocol: a value type with a
/// `body` built from other views. The engine evaluates a view by walking
/// `body` until it reaches a primitive view (``Text``, ``Button``, a stack,
/// etc.), then turns the result into an ``Element`` tree.
public protocol View {
  associatedtype Body: View

  @ViewBuilder var body: Body { get }
}

/// A view the engine knows how to turn into an element directly. Not public:
/// users compose ``View`` values and never implement this.
protocol _PrimitiveView: View {
  func _makeElement(path: [Int]) -> Element
}

/// Evaluates `view` and its `body` chain down to a primitive element.
///
/// The path is the structural position used for `@State` storage scopes; it is
/// distinct from the diff identity, which also honours `.id(_:)`.
func _render<V: View>(_ view: V, path: [Int]) -> Element {
  if let primitive = view as? any _PrimitiveView {
    return primitive._makeElement(path: path)
  }
  // Child views are constructed while this body runs, so they register their
  // @State slots under this path.
  let body = StateRegistry.shared.withScope(path) { view.body }
  return _render(body, path: path)
}

/// A type-erased view.
///
/// `AnyView` is mostly an escape hatch for code that needs to store or return
/// differently typed views. It hides the concrete type from the diff's kind
/// comparison, so prefer concrete views and generic containers.
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

// `Never` is the `Body` of every primitive view. It has no values, so the body
// getter can never run; the conformance exists so the associated type is valid.
extension Never: View {
  public typealias Body = Never
  public var body: Never { return fatalError("Never has no body") }
}
