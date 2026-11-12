@testable import SwiftUIRuntime
import XCTest

private struct CounterView: View {
  @State var count = 0

  var body: some View {
    VStack(spacing: 8) {
      Text("Count: \(count)")
      Button("Increment") { count += 1 }
    }
  }
}

private struct BindingChild: View {
  @Binding var value: Int

  var body: some View {
    Button("Add") { value += 1 }
  }
}

private struct BindingParent: View {
  @State var value = 0

  var body: some View {
    VStack(spacing: 0) {
      Text("Value: \(value)")
      BindingChild(value: $value)
    }
  }
}

private struct ToggleView: View {
  @State var showExtra = false

  var body: some View {
    VStack(spacing: 0) {
      Button("Toggle") { showExtra.toggle() }
      if showExtra {
        Text("Extra")
      }
    }
  }
}

final class StateTests: XCTestCase {
  override func setUp() {
    super.setUp()
    StateRegistry.shared.reset()
  }

  func testStateWriteRerendersAndUpdatesPropsOnly() {
    let backend = FakeBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(CounterView()),
      size: Size(width: 320, height: 200)
    )
    renderer.mount()
    backend.reset()

    guard let tree = renderer.tree,
          let button = findNode(in: tree, kind: .button)
    else {
      return XCTFail("expected a button")
    }

    backend.tap(button.id)

    XCTAssertEqual(count(renderer.lastCommands, where: \.isCreate), 0)
    XCTAssertEqual(count(renderer.lastCommands, where: \.isRemove), 0)
    XCTAssertEqual(count(renderer.lastCommands, where: \.isSetProps), 1)

    guard let updated = renderer.tree,
          let text = findNode(in: updated, kind: .text)
    else {
      return XCTFail("expected a text node")
    }
    XCTAssertEqual(text.props.text, "Count: 1")
  }

  func testBindingWriteFlowsBackToParentState() {
    let backend = FakeBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(BindingParent()),
      size: Size(width: 320, height: 200)
    )
    renderer.mount()
    backend.reset()

    guard let tree = renderer.tree,
          let button = findNode(in: tree, kind: .button)
    else {
      return XCTFail("expected a button")
    }

    backend.tap(button.id)

    guard let updated = renderer.tree,
          let text = findNode(in: updated, kind: .text)
    else {
      return XCTFail("expected a text node")
    }
    XCTAssertEqual(text.props.text, "Value: 1")
    XCTAssertEqual(count(renderer.lastCommands, where: \.isCreate), 0)
    XCTAssertEqual(count(renderer.lastCommands, where: \.isRemove), 0)
  }

  func testResizeEmitsRootFrameChange() {
    let backend = FakeBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(VStack { Text("A") }),
      size: Size(width: 200, height: 100)
    )
    renderer.mount()
    backend.reset()

    renderer.resize(to: Size(width: 400, height: 300))

    XCTAssertEqual(renderer.tree?.frame, Rect(x: 0, y: 0, width: 400, height: 300))
    XCTAssertTrue(
      renderer.lastCommands.contains {
        if case .setFrame(_, let frame) = $0 {
          return frame == Rect(x: 0, y: 0, width: 400, height: 300)
        }
        return false
      }
    )
  }

  func testConditionalContentInsertsAndRemoves() {
    let backend = FakeBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(ToggleView()),
      size: Size(width: 100, height: 100)
    )
    renderer.mount()
    XCTAssertNil(findNode(in: renderer.tree!, text: "Extra"))

    guard let button = findNode(in: renderer.tree!, kind: .button) else {
      return XCTFail("expected a toggle button")
    }

    backend.tap(button.id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "Extra"))
    XCTAssertEqual(count(renderer.lastCommands, where: \.isCreate), 1)
    XCTAssertEqual(count(renderer.lastCommands, where: \.isRemove), 0)

    backend.tap(button.id)
    XCTAssertNil(findNode(in: renderer.tree!, text: "Extra"))
    XCTAssertEqual(count(renderer.lastCommands, where: \.isRemove), 1)
    XCTAssertEqual(count(renderer.lastCommands, where: \.isCreate), 0)
  }
}
