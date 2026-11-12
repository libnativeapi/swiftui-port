import Foundation

/// The slot a `@State` wrapper reads and writes.
struct StateKey: Hashable {
  let scope: [Int]
  let ordinal: Int
}

/// Process-wide state storage shared by `@State` wrappers.
///
/// SwiftUI keeps state in framework-owned storage keyed by view identity. This
/// is a small runtime approximation:
///
/// * Each call to `@State.init` registers a slot `(scope, ordinal)`.
/// * `scope` is the structural path of the view whose body is being evaluated.
/// * `ordinal` resets per body evaluation, so re-creating the same view value
///   in the same position finds the same slot.
///
/// The consequence is that state is tied to the position where a view value is
/// constructed, not to an explicit `.id`. See docs/DIVERGENCES.md.
public final class StateRegistry {
  public static let shared = StateRegistry()

  private var values: [StateKey: Any] = [:]
  private var scope: [Int] = []
  private var ordinal = 0
  private var renderingDepth = 0

  /// The renderer installs a callback here so a `@State` write can schedule a
  /// new body evaluation.
  public var onChange: (() -> Void)?

  private init() {}

  /// Drops all stored slots. Intended for tests; an app uses one registry.
  public func reset() {
    values.removeAll()
    scope = []
    ordinal = 0
    renderingDepth = 0
    onChange = nil
  }

  func withScope<T>(_ newScope: [Int], _ body: () -> T) -> T {
    let savedScope = scope
    let savedOrdinal = ordinal
    scope = newScope
    ordinal = 0
    renderingDepth += 1
    defer {
      renderingDepth -= 1
      scope = savedScope
      ordinal = savedOrdinal
    }
    return body()
  }

  func register<Value>(_ initialValue: Value) -> StateKey {
    let key = StateKey(scope: scope, ordinal: ordinal)
    ordinal += 1
    if values[key] == nil {
      values[key] = initialValue
    }
    return key
  }

  func value<Value>(for key: StateKey, default defaultValue: Value) -> Value {
    values[key] as? Value ?? defaultValue
  }

  func set<Value>(_ value: Value, for key: StateKey) {
    values[key] = value
    // A write during body evaluation is legal, but the current pass must finish
    // before the next one starts; the renderer coalesces it.
    onChange?()
  }
}

/// A mutable value owned by the view that declares it.
///
/// ```swift
/// struct CounterView: View {
///   @State private var count = 0
///   var body: some View {
///     Button("Increment") { count += 1 }
///   }
/// }
/// ```
///
/// v0.1 supports state in the root view and in child views whose construction
/// order is stable. `@StateObject` and `ObservableObject` are not implemented.
@propertyWrapper
public struct State<Value> {
  private let key: StateKey
  private let initialValue: Value

  public init(wrappedValue: Value) {
    self.initialValue = wrappedValue
    self.key = StateRegistry.shared.register(wrappedValue)
  }

  public init(initialValue: Value) {
    self.init(wrappedValue: initialValue)
  }

  public var wrappedValue: Value {
    get { StateRegistry.shared.value(for: key, default: initialValue) }
    nonmutating set { StateRegistry.shared.set(newValue, for: key) }
  }

  public var projectedValue: Binding<Value> {
    Binding(
      get: { StateRegistry.shared.value(for: key, default: initialValue) },
      set: { StateRegistry.shared.set($0, for: key) }
    )
  }
}
