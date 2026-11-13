public struct ButtonStyleConfiguration {
  public typealias Label = AnyView
  public let label: Label
  public let isPressed: Bool
}
@MainActor @preconcurrency public protocol ButtonStyle {
  associatedtype Body: View
  typealias Configuration = ButtonStyleConfiguration
  @ViewBuilder func makeBody(configuration: Configuration) -> Body
}
struct StyledButton<Label: View, Style: ButtonStyle>: View, _PrimitiveView {
  typealias Body = Never
  let button: Button<Label>
  let style: Style
  @State private var pressed = false
  init(button: Button<Label>, style: Style) {
    self.button = button
    self.style = style
  }
  var body: Never { fatalError("StyledButton is primitive") }
  func _makeElement(path: ViewPath) -> Element {
    let content = style.makeBody(
      configuration: ButtonStyleConfiguration(label: AnyView(button.label), isPressed: pressed))
    var element = Element(
      kind: .styledButton, children: [_render(content, path: path.appending(index: 0))], action: button.action)
    element.pressedAction = { if pressed != $0 { pressed = $0 } }
    return element
  }
}
extension Button {
  public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
    StyledButton(button: self, style: style)
  }
}
