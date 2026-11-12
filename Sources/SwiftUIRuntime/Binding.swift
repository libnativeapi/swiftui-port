/// A reference to a value owned elsewhere.
///
/// A child view takes a binding with `@Binding var value: T` and the parent
/// passes `$value`. Reads and writes go straight to the owner's storage, so a
/// write marks the renderer dirty exactly as a direct `@State` write does.
@propertyWrapper
public struct Binding<Value> {
  private let getter: () -> Value
  private let setter: (Value) -> Void

  public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
    self.getter = get
    self.setter = set
  }

  public var wrappedValue: Value {
    get { getter() }
    nonmutating set { setter(newValue) }
  }

  public var projectedValue: Binding<Value> { self }

  /// A binding that ignores writes. Reads always return `value`.
  public static func constant(_ value: Value) -> Binding<Value> {
    Binding(get: { value }, set: { _ in })
  }
}
