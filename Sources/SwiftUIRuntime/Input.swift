import Foundation

public struct EventModifiers: OptionSet, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = Self(rawValue: 1), control = Self(rawValue: 2),
    option = Self(rawValue: 4), command = Self(rawValue: 8)
}
public struct KeyEquivalent: Hashable, ExpressibleByExtendedGraphemeClusterLiteral {
  public let character: Character
  public init(_ character: Character) { self.character = character }
  public init(extendedGraphemeClusterLiteral value: String) { character = value.first! }
  public static let escape = Self("\u{1b}"), `return` = Self("\r"), space = Self(" "),
    tab = Self("\t"), delete = Self("\u{8}"), deleteForward = Self("\u{7f}")
  public static let leftArrow = Self("\u{f702}"), rightArrow = Self("\u{f703}"),
    upArrow = Self("\u{f700}"), downArrow = Self("\u{f701}")
  public static let home = Self("\u{f729}"), end = Self("\u{f72b}"), pageUp = Self("\u{f72c}"),
    pageDown = Self("\u{f72d}")
}
public struct KeyboardShortcut: Equatable {
  public let key: KeyEquivalent
  public let modifiers: EventModifiers
  public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
    self.key = key
    self.modifiers = modifiers
  }
  public static let cancelAction = Self(.escape, modifiers: []),
    defaultAction = Self(.return, modifiers: [])
}
public struct KeyPress {
  public struct Phases: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let down = Self(rawValue: 1), `repeat` = Self(rawValue: 2), up = Self(rawValue: 4)
  }
  public enum Result { case handled, ignored }
  public let key: KeyEquivalent
  public let characters: String
  public let modifiers: EventModifiers
  public init(key: KeyEquivalent, characters: String = "", modifiers: EventModifiers = []) {
    self.key = key
    self.characters = characters
    self.modifiers = modifiers
  }
}
public enum MoveCommandDirection { case left, right, up, down }
public protocol Gesture {
  var changed: ((DragGesture.Value) -> Void)? { get }
  var ended: ((DragGesture.Value) -> Void)? { get }
}
public struct DragGesture: Gesture {
  public struct Value {
    public let location: CGPoint
    public let startLocation: CGPoint
    public let translation: CGSize
    public let time: Date
  }
  public let minimumDistance: CGFloat
  public var changed: ((Value) -> Void)?
  public var ended: ((Value) -> Void)?
  public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
    self.minimumDistance = minimumDistance
  }
  public func onChanged(_ action: @escaping (Value) -> Void) -> Self {
    var g = self
    g.changed = action
    return g
  }
  public func onEnded(_ action: @escaping (Value) -> Void) -> Self {
    var g = self
    g.ended = action
    return g
  }
}
public struct TextField: View, _PrimitiveView {
  public typealias Body = Never
  let title: String
  let text: Binding<String>
  let axis: Axis
  var secure = false
  public init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
    self.title = title
    self.text = text
    self.axis = axis
  }
  public var body: Never { fatalError() }
  func _makeElement(path: [Int]) -> Element {
    var p = NodeProps()
    p.text = text.wrappedValue
    p.placeholder = title
    p.multiline = axis == .vertical
    p.secure = secure
    p.font = EnvironmentValues.current.font
    p.fillWidth = true
    var e = Element(kind: .textField, props: p)
    e.textAction = { if text.wrappedValue != $0 { text.wrappedValue = $0 } }
    return e
  }
}
public struct SecureField: View {
  let title: String
  let text: Binding<String>
  public init(_ title: String, text: Binding<String>) {
    self.title = title
    self.text = text
  }
  public var body: some View {
    var field = TextField(title, text: text)
    field.secure = true
    return field
  }
}
public struct PlainTextFieldStyle { public static let plain = Self() }
public struct PlainButtonStyle: ButtonStyle {
  public init() {}
  public func makeBody(configuration: Configuration) -> some View { configuration.label }
  public static let plain = Self()
}
extension ButtonStyle where Self == PlainButtonStyle { public static var plain: Self { Self() } }
extension View {
  public func textFieldStyle(_ style: PlainTextFieldStyle) -> some View { self }
  public func onSubmit(_ action: @escaping () -> Void) -> some View {
    TransformView(content: self) { $0.submitAction = action }
  }
  public func gesture<G: Gesture>(_ gesture: G) -> some View {
    TransformView(content: self) {
      $0.dragAction = { value, ended in
        if ended { gesture.ended?(value) } else { gesture.changed?(value) }
      }
    }
  }
  public func onTapGesture(count: Int, perform action: @escaping () -> Void) -> some View {
    TransformView(content: self) {
      if count == 2 { $0.doubleTapAction = action } else { $0.action = action }
    }
  }
  public func onKeyPress(
    phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result
  ) -> some View {
    TransformView(content: self) {
      let previous = $0.keyAction
      $0.keyAction = { key in action(key) == .handled ? .handled : previous?(key) ?? .ignored }
    }
  }
  public func onMoveCommand(perform action: @escaping (MoveCommandDirection) -> Void) -> some View {
    onKeyPress { press in
      switch press.key {
      case .leftArrow: action(.left)
      case .rightArrow: action(.right)
      case .upArrow: action(.up)
      case .downArrow: action(.down)
      default: return .ignored
      }
      return .handled
    }
  }
  public func onExitCommand(perform action: @escaping () -> Void) -> some View {
    onKeyPress { key in
      if key.key == .escape {
        action()
        return .handled
      }
      return .ignored
    }
  }
  public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command)
    -> some View
  { keyboardShortcut(KeyboardShortcut(key, modifiers: modifiers)) }
  public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
    TransformView(content: self) { $0.props.keyboardShortcut = shortcut }
  }
  public func focusable(_ focusable: Bool = true) -> some View {
    TransformView(content: self) { $0.props.focusable = focusable }
  }
  public func focusEffectDisabled(_ disabled: Bool = true) -> some View { self }  // all custom focus decoration belongs to view styles
  public func focused<Value: Hashable>(_ binding: FocusState<Value?>.Binding, equals value: Value)
    -> some View
  {
    TransformView(content: self) {
      $0.focusAction = { binding.set($0 ? value : nil) }
      $0.props.focusRequested = binding.get() == value
    }
  }
}
public enum AccessibilityChildBehavior { case contain, combine, ignore }
public enum AccessibilityAdjustmentDirection { case increment, decrement }
public struct AccessibilityTraits: OptionSet {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let isSelected = Self(rawValue: 1), isButton = Self(rawValue: 2),
    isHeader = Self(rawValue: 4), isLink = Self(rawValue: 8), isImage = Self(rawValue: 16),
    isModal = Self(rawValue: 32)
}
extension View {
  public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
    self
  }
  public func accessibilityLabel(_ text: String) -> some View {
    TransformView(content: self) { $0.props.accessibilityLabel = text }
  }
  public func accessibilityLabel(_ text: Text) -> some View { accessibilityLabel(text.content) }
  public func accessibilityValue(_ text: String) -> some View {
    TransformView(content: self) { $0.props.accessibilityValue = text }
  }
  public func accessibilityValue(_ text: Text) -> some View { accessibilityValue(text.content) }
  public func accessibilityHidden(_ value: Bool) -> some View {
    TransformView(content: self) { $0.props.accessibilityHidden = value }
  }
  public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
    TransformView(content: self) { $0.props.accessibilityTraits = traits.rawValue }
  }
  public func accessibilityAdjustableAction(
    _ action: @escaping (AccessibilityAdjustmentDirection) -> Void
  ) -> some View {
    onMoveCommand { direction in
      action(direction == .up || direction == .right ? .increment : .decrement)
    }
  }
}
