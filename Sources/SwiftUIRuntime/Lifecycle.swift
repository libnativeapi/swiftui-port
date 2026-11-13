/// Lifecycle work is collected during evaluation and delivered only after the
/// resulting tree is mounted. Re-evaluating body is not an appearance event.
import Foundation

final class LifecycleRegistry {
  static let shared = LifecycleRegistry()
  struct Entry {
    var value: AnyHashable
    var disappear: (() -> Void)?
    var task: Task<Void, Never>?
  }
  var entries: [StateKey: Entry] = [:]
  var live = Set<StateKey>()
  var pending: [() -> Void] = []
  func retain(_ keys: Set<StateKey>) {
    live.formUnion(keys)
    GeometrySnapshot.active?.lifecycle.formUnion(keys)
  }
  func begin() {
    live.removeAll()
    pending.removeAll()
  }
  func register(
    _ key: StateKey, value: AnyHashable, appear: (() -> Void)?, change: (() -> Void)?,
    disappear: (() -> Void)?, task: (() async -> Void)?
  ) {
    EvaluationGraph.active?.installLifecycle(key)
    GeometrySnapshot.active?.lifecycle.insert(key)
    live.insert(key)
    let old = entries[key]
    if old == nil || old!.value != value {
      old?.task?.cancel()
      var entry = Entry(value: value, disappear: disappear)
      if old == nil, let appear { pending.append(appear) }
      if old != nil, let change { pending.append(change) }
      if let task {
        pending.append { self.entries[key]?.task = Task { @MainActor in await task() } }
      }
      entry.task = nil
      entries[key] = entry
    } else {
      entries[key]?.disappear = disappear
    }
  }
  func commit() {
    for key in Set(entries.keys).subtracting(live) {
      LifecycleSnapshots.shared.values.removeValue(forKey: key)
      LifecycleSnapshots.shared.versions.removeValue(forKey: key)
      let old = entries.removeValue(forKey: key)
      old?.task?.cancel()
      if let action = old?.disappear { pending.append(action) }
    }
    let work = pending
    pending.removeAll()
    work.forEach { $0() }
  }
  func reset() {
    entries.values.forEach { $0.task?.cancel() }
    entries.removeAll()
    pending.removeAll()
    LifecycleSnapshots.shared.values.removeAll()
    LifecycleSnapshots.shared.versions.removeAll()
  }
}
struct LifecycleView<Content: View, Value: Equatable>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let value: Value
  let appear: (() -> Void)?
  let change: ((Value) -> Void)?
  let disappear: (() -> Void)?
  let task: (() async -> Void)?
  var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    // Equatable values need not be Hashable. Keep a comparison snapshot without
    // publishing internal bookkeeping as an application state mutation.
    let key = StateKey(path: path, owner: ObjectIdentifier(Self.self), property: -1)
    let snapshot = LifecycleSnapshots.shared.values[key] as? Value
    let changed = snapshot == nil || snapshot! != value
    let version = LifecycleSnapshots.shared.versions[key, default: 0] + (changed ? 1 : 0)
    LifecycleSnapshots.shared.values[key] = value
    LifecycleSnapshots.shared.versions[key] = version
    LifecycleRegistry.shared.register(
      key, value: version, appear: appear, change: { change?(value) }, disappear: disappear,
      task: task)
    return _render(content, path: path + [0])
  }
}
private final class LifecycleSnapshots {
  static let shared = LifecycleSnapshots()
  var values: [StateKey: Any] = [:]
  var versions: [StateKey: Int] = [:]
}
extension View {
  public func onAppear(perform action: (() -> Void)? = nil) -> some View {
    LifecycleView(
      content: self, value: false, appear: action, change: nil, disappear: nil, task: nil)
  }
  public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
    LifecycleView(
      content: self, value: false, appear: nil, change: nil, disappear: action, task: nil)
  }
  public func onChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void)
    -> some View
  {
    LifecycleView(
      content: self, value: value, appear: nil, change: action, disappear: nil, task: nil)
  }
  public func task<ID: Equatable>(id: ID, _ action: @escaping () async -> Void) -> some View {
    LifecycleView(content: self, value: id, appear: nil, change: nil, disappear: nil, task: action)
  }
  public func task(_ action: @escaping () async -> Void) -> some View { task(id: false, action) }
}
