/// Environment writes are value copies scoped to evaluating a subtree.

public protocol EnvironmentKey {
  associatedtype Value
  static var defaultValue: Value { get }
}
public enum ColorScheme: Sendable { case light, dark }
public struct EnvironmentValues {
  var objects: [ObjectIdentifier: AnyObject] = [:]
  private var values: [ObjectIdentifier: Any] = [:]
  public var foregroundColor: Color?
  public var isEnabled: Bool
  public var layoutDirection: LayoutDirection = .leftToRight
  public var colorScheme: ColorScheme = .light
  public var tint: Color = .blue
  public var font: Font? = nil
  public var accessibilityReduceMotion = false
  public init(foregroundColor: Color? = nil, isEnabled: Bool = true) {
    self.foregroundColor = foregroundColor
    self.isEnabled = isEnabled
  }
  public subscript<K: EnvironmentKey>(_ key: K.Type) -> K.Value {
    get { values[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
    set { values[ObjectIdentifier(key)] = newValue }
  }
  public static let `default` = EnvironmentValues()
  static var current = EnvironmentValues()
}
@propertyWrapper public struct Environment<Value>: _EnvironmentProperty {
  private final class Storage { var value: Value? }
  private let storage = Storage()
  let keyPath: KeyPath<EnvironmentValues, Value>
  public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }
  public var wrappedValue: Value { storage.value ?? EnvironmentValues.current[keyPath: keyPath] }
  func installEnvironment() { storage.value = EnvironmentValues.current[keyPath: keyPath] }
}
struct EnvironmentView<Content: View, Value>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content
  let keyPath: WritableKeyPath<EnvironmentValues, Value>
  let value: Value
  var body: Never { fatalError("EnvironmentView is primitive") }
  func _makeElement(path: [Int]) -> Element {
    let saved = EnvironmentValues.current
    EnvironmentValues.current[keyPath: keyPath] = value
    defer { EnvironmentValues.current = saved }
    return _render(content, path: path)
  }
}
extension View {
  public func environment<Value>(
    _ keyPath: WritableKeyPath<EnvironmentValues, Value>, _ value: Value
  ) -> some View {
    EnvironmentView(content: self, keyPath: keyPath, value: value)
  }
}
