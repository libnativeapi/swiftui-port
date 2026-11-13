import XCTest

@testable import SwiftUIRuntime

private struct MarkerKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
  fileprivate var marker: Int {
    get { self[MarkerKey.self] }
    set { self[MarkerKey.self] = newValue }
  }
}
private struct Marker: View {
  @Environment(\.marker) var marker
  var body: some View { Text("marker:\(marker)") }
}
private struct CountingChild: View {
  let name: String
  @State var count = 0
  var body: some View {
    VStack {
      Text("\(name):\(count)")
      Button(name) { count += 1 }
    }
  }
}
private struct CountingParent: View {
  @State var extra = false
  var body: some View {
    VStack {
      CountingChild(name: "first")
      CountingChild(name: "second")
      Button("toggle") { extra.toggle() }
      if extra { CountingChild(name: "temporary") }
    }
  }
}
private struct TestStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.padding(8)
      .background { RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? .red : .blue) }
  }
}
private struct CountingModifier: ViewModifier {
  @Environment(\.marker) var marker
  @State var count = 0
  func body(content: Content) -> some View {
    VStack {
      content
      Button("\(marker):\(count)") { count += 1 }
    }
  }
}
private struct EnabledLabel: View {
  @Environment(\.isEnabled) var enabled
  var body: some View { Text(enabled ? "enabled" : "disabled") }
}

final class StyledViewTests: XCTestCase {
  override func setUp() { StateRegistry.shared.reset() }
  private func render<V: View>(_ view: V) -> Renderer {
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(view), size: Size(width: 400, height: 240))
    renderer.mount()
    return renderer
  }
  private func nodes(_ node: Element) -> [Element] { [node] + node.children.flatMap(nodes) }

  func testEnvironmentAndFontAreScopedThroughErasureAndSiblings() {
    let renderer = render(
      VStack {
        AnyView(Marker().environment(\.marker, 7).font(.system(size: 22)))
        Marker()
      }.environment(\.marker, 3).font(.system(size: 11)))
    let texts = nodes(renderer.tree!).filter { $0.kind == .text }
    XCTAssertEqual(texts.map(\.props.text), ["marker:7", "marker:3"])
    XCTAssertEqual(texts.map { $0.props.font?.size }, [22, 11])
    XCTAssertEqual(EnvironmentValues.current.marker, 0)
  }

  func testSiblingStatePersistsIndependentlyAcrossReevaluation() throws {
    let renderer = render(CountingParent())
    let second = try XCTUnwrap(nodes(renderer.tree!).first { $0.props.text == "second" })
    renderer.performTap(second.id)
    renderer.performTap(second.id)
    let texts = nodes(renderer.tree!).map(\.props.text)
    XCTAssertTrue(texts.contains("first:0"))
    XCTAssertTrue(texts.contains("second:2"))
    XCTAssertFalse(
      renderer.lastCommands.contains {
        if case .create = $0 { return true }
        return false
      })
  }

  func testRemovedStateStartsFreshWhenInsertedAgain() throws {
    let renderer = render(CountingParent())
    let toggle = try XCTUnwrap(nodes(renderer.tree!).first { $0.props.text == "toggle" })
    renderer.performTap(toggle.id)
    let temporary = try XCTUnwrap(nodes(renderer.tree!).first { $0.props.text == "temporary" })
    renderer.performTap(temporary.id)
    renderer.performTap(toggle.id)
    renderer.performTap(toggle.id)
    XCTAssertTrue(nodes(renderer.tree!).contains { $0.props.text == "temporary:0" })
  }

  func testStyledButtonPressedStateAndDisabledActivation() throws {
    var count = 0
    let renderer = render(
      HStack {
        Button("enabled") { count += 1 }.buttonStyle(TestStyle())
        Button("disabled") { count += 100 }.buttonStyle(TestStyle()).disabled()
      })
    let buttons = nodes(renderer.tree!).filter { $0.kind == .styledButton }
    XCTAssertEqual(buttons.count, 2)
    renderer.interact(buttons[0].id, .pressed(true))
    XCTAssertTrue(
      nodes(renderer.tree!).contains { $0.kind == .shape && $0.props.background == .red })
    XCTAssertFalse(
      renderer.lastCommands.contains {
        if case .create = $0 { return true }
        return false
      })
    renderer.performTap(buttons[0].id)
    renderer.performTap(buttons[1].id)
    XCTAssertEqual(count, 1)
    renderer.interact(buttons[0].id, .pressed(false))
    XCTAssertFalse(
      nodes(renderer.tree!).contains { $0.kind == .shape && $0.props.background == .red })
  }

  func testFrameDoesNotCollapseModifierOrderOrGrowForOverlay() {
    let renderer = render(
      VStack {
        Text("A").frame(width: 40, height: 30)
          .padding(5).background(.blue)
          .overlay { Rectangle().strokeBorder(.red, lineWidth: 2).padding(-2) }
      })
    let child = renderer.tree!.children[0]
    XCTAssertEqual(child.frame.width, 50)
    XCTAssertEqual(child.frame.height, 40)
    let text = nodes(child).first { $0.kind == .text }!
    XCTAssertEqual(text.frame.width, 8)
    XCTAssertEqual(text.frame.height, 20)
    XCTAssertEqual(text.frame.minX, child.frame.minX + 21)
  }

  func testModifierReadsScopedEnvironmentAndRetainsState() throws {
    let renderer = render(Text("content").modifier(CountingModifier()).environment(\.marker, 9))
    let button = try XCTUnwrap(nodes(renderer.tree!).first { $0.kind == .button })
    XCTAssertEqual(button.props.text, "9:0")
    renderer.performTap(button.id)
    XCTAssertTrue(nodes(renderer.tree!).contains { $0.props.text == "9:1" })
  }

  func testFlexibleDividerFillsPaddedStackWithoutGrowingItsHeight() throws {
    let renderer = render(
      VStack(alignment: .leading, spacing: 0) {
        Text("A")
        Rectangle().fill(.blue).frame(height: 1).frame(maxWidth: .infinity)
      }.padding(10))
    let shape = try XCTUnwrap(nodes(renderer.tree!).first { $0.kind == .shape })
    XCTAssertEqual(shape.frame.width, 380)
    XCTAssertEqual(shape.frame.height, 1)
  }

  func testUnstyledLabelBuilderUsesNativeTitle() throws {
    let renderer = render(
      Button(action: {}) {
        HStack {
          Text("Save")
          Text("document")
        }
      })
    XCTAssertEqual(renderer.tree?.props.text, "Save document")
  }

  func testDisabledIsVisibleToEnvironmentReadersAndScopedToSubtree() {
    let renderer = render(
      VStack {
        EnabledLabel().disabled()
        EnabledLabel()
      })
    let texts = nodes(renderer.tree!).filter { $0.kind == .text }
    XCTAssertEqual(texts.map(\.props.text), ["disabled", "enabled"])
    XCTAssertEqual(texts.map(\.props.enabled), [false, true])
  }
}
