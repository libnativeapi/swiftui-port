/// State belongs to a mounted view/property, not the place its value was
/// constructed. Two same-typed siblings therefore keep independent slots.

struct StateKey: Hashable {
  let path: [Int]
  let owner: ObjectIdentifier
  let property: Int
}
protocol _StateProperty { func install(_ key: StateKey) }
public final class StateRegistry {
  public static let shared = StateRegistry()
  private var values: [StateKey: Any] = [:]
  private var live: Set<StateKey> = []
  public var onChange: (() -> Void)?
  var onStateChange: ((StateKey) -> Void)?
  private init() {}
  public func reset() {
    LifecycleRegistry.shared.reset()
    values.removeAll()
    live.removeAll()
    onChange = nil
    onStateChange = nil
  }
  func begin() { live.removeAll() }
  func retain(_ keys: Set<StateKey>) {
    live.formUnion(keys)
    GeometrySnapshot.active?.state.formUnion(keys)
  }
  func end() { values = values.filter { live.contains($0.key) } }
  func withScope<T>(_ scope: [Int], _ body: () -> T) -> T { body() }
  func install<Value>(_ key: StateKey, initial: Value) {
    EvaluationGraph.active?.installState(key)
    GeometrySnapshot.active?.state.insert(key)
    live.insert(key)
    if values[key] == nil { values[key] = initial }
  }
  func installLazy<Value>(_ key: StateKey, initial: () -> Value) -> Value {
    EvaluationGraph.active?.installState(key)
    GeometrySnapshot.active?.state.insert(key)
    live.insert(key)
    if let value = values[key] as? Value { return value }
    let value = initial()
    values[key] = value
    return value
  }
  func value<Value>(_ key: StateKey, initial: Value) -> Value {
    EvaluationGraph.active?.read(key)
    return values[key] as? Value ?? initial
  }
  func set<Value>(_ key: StateKey, value: Value) {
    func equal<T: Equatable>(_ lhs: T, _ rhs: Any) -> Bool { (rhs as? T) == lhs }
    if let old = values[key] as? any Equatable, equal(old, value) { return }
    values[key] = value
    if let onStateChange { onStateChange(key) } else { onChange?() }
  }
}
@propertyWrapper public struct State<Value>: _StateProperty {
  private final class Storage {
    var value: Value
    var key: StateKey?
    init(_ value: Value) { self.value = value }
  }
  private let storage: Storage
  public init(wrappedValue: Value) { storage = Storage(wrappedValue) }
  public init(initialValue: Value) { self.init(wrappedValue: initialValue) }
  func install(_ key: StateKey) {
    storage.key = key
    StateRegistry.shared.install(key, initial: storage.value)
  }
  public var wrappedValue: Value {
    get {
      guard let key = storage.key else { return storage.value }
      return StateRegistry.shared.value(key, initial: storage.value)
    }
    nonmutating set {
      storage.value = newValue
      if let key = storage.key { StateRegistry.shared.set(key, value: newValue) }
    }
  }
  public var projectedValue: Binding<Value> {
    Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
  }
  var installedKey: StateKey? { storage.key }
}
