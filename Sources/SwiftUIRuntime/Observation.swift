import Foundation

public protocol ObservableObject: AnyObject {}
public final class ObservableObjectPublisher {
  public init() {}
  public func send() { StateRegistry.shared.onChange?() }
}
extension ObservableObject {
  public var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}
@propertyWrapper public struct Published<Value> {
  private final class Storage {
    var value: Value
    init(_ value: Value) { self.value = value }
  }
  private let storage: Storage
  public var wrappedValue: Value {
    get { storage.value }
    nonmutating set {
      storage.value = newValue
      StateRegistry.shared.onChange?()
    }
  }
  public init(wrappedValue: Value) { storage = Storage(wrappedValue) }
}
@propertyWrapper @dynamicMemberLookup public struct ObservedObject<Object: ObservableObject> {
  public var wrappedValue: Object
  public init(wrappedValue: Object) { self.wrappedValue = wrappedValue }
  public init(initialValue: Object) { self.wrappedValue = initialValue }
  public var projectedValue: Self { self }
  public subscript<Value>(dynamicMember key: ReferenceWritableKeyPath<Object, Value>) -> Binding<
    Value
  > {
    Binding(get: { wrappedValue[keyPath: key] }, set: { wrappedValue[keyPath: key] = $0 })
  }
}
@propertyWrapper public struct StateObject<Object: ObservableObject>: _StateProperty {
  private final class Storage {
    let make: () -> Object
    var value: Object?
    init(make: @escaping () -> Object) { self.make = make }
    func get() -> Object {
      if let value { return value }
      let object = make()
      value = object
      return object
    }
  }
  private let storage: Storage
  public init(wrappedValue: @autoclosure @escaping () -> Object) {
    storage = Storage(make: wrappedValue)
  }
  public var wrappedValue: Object { storage.get() }
  public var projectedValue: ObservedObject<Object> { ObservedObject(wrappedValue: wrappedValue) }
  func install(_ key: StateKey) {
    storage.value = StateRegistry.shared.installLazy(key) { storage.get() }
  }
}
protocol _EnvironmentProperty { func installEnvironment() }
@propertyWrapper @dynamicMemberLookup
public struct EnvironmentObject<Object: ObservableObject>: _EnvironmentProperty {
  private final class Storage { var object: Object? }
  private let storage = Storage()
  public init() {}
  public var wrappedValue: Object {
    guard
      let object = storage.object ?? EnvironmentValues.current.objects[
        ObjectIdentifier(Object.self)] as? Object
    else {
      preconditionFailure("Missing environment object \(Object.self)")
    }
    return object
  }
  public var projectedValue: ObservedObject<Object> { ObservedObject(wrappedValue: wrappedValue) }
  public subscript<Value>(dynamicMember key: KeyPath<Object, Value>) -> Value {
    wrappedValue[keyPath: key]
  }
  func installEnvironment() {
    storage.object = EnvironmentValues.current.objects[ObjectIdentifier(Object.self)] as? Object
  }
}
struct ObjectEnvironment<Content: View, Object: ObservableObject>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let object: Object
  var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    let old = EnvironmentValues.current
    EnvironmentValues.current.objects[ObjectIdentifier(Object.self)] = object
    defer { EnvironmentValues.current = old }
    return _render(content, path: path)
  }
}
extension View {
  public func environmentObject<Object: ObservableObject>(_ object: Object) -> some View {
    ObjectEnvironment(content: self, object: object)
  }
}
