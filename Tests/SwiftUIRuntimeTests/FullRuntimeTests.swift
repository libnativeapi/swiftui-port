import XCTest
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

@testable import SwiftUIRuntime

final class FullRuntimeTests: XCTestCase {
  private final class Model: SwiftUIRuntime.ObservableObject {
    static var constructions = 0
    @SwiftUIRuntime.Published var count = 0
    init() { Self.constructions += 1 }
  }
  private struct OwnedModel: View {
    @StateObject var model = Model()
    var body: some View { Button(String(model.count)) { model.count += 1 } }
  }
  private struct ModelParent: View { var body: some View { OwnedModel() } }
  func testStateObjectIsCreatedOnceAndPublishedChangesRender() throws {
    StateRegistry.shared.reset()
    Model.constructions = 0
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(ModelParent()), size: .init(width: 300, height: 200))
    renderer.mount()
    let button = try XCTUnwrap(findNode(in: renderer.tree!, kind: .button))
    renderer.performTap(button.id)
    renderer.performTap(button.id)
    XCTAssertEqual(Model.constructions, 1)
    XCTAssertEqual(findNode(in: renderer.tree!, kind: .button)?.props.text, "2")
  }
  private struct Scroller: View {
    var body: some View {
      VStack(spacing: 0) {
        Text("Header").frame(height: 40)
        ScrollView { VStack { ForEach(0..<50) { Text("Row " + String($0)).frame(height: 24) } } }
      }
    }
  }
  func testScrollViewUsesRemainingHeightAndClampsInput() throws {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(),
      root: AnyView(
        Scroller().overlay {
          ZStack { EmptyView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }), size: .init(width: 300, height: 200))
    renderer.mount()
    let scroll = try XCTUnwrap(findNode(in: renderer.tree!, kind: .scroll))
    XCTAssertEqual(scroll.frame.minY, 40)
    XCTAssertEqual(scroll.frame.height, 160)
    renderer.input(event: 5, point: CGPoint(x: 100, y: 100), value: -120)
    XCTAssertEqual(findNode(in: renderer.tree!, kind: .scroll)?.props.scrollOffset.y, 48)
    renderer.input(event: 5, point: CGPoint(x: 100, y: 100), value: 12000)
    XCTAssertEqual(findNode(in: renderer.tree!, kind: .scroll)?.props.scrollOffset.y, 0)
  }
  private struct PopoverProbe: View {
    @State var open = false
    var body: some View {
      ScrollView {
        Button("Show") { open = true }.popover(isPresented: $open) {
          Button("Dismiss") { open = false }
        }
      }.frame(width: 200, height: 100)
    }
  }
  func testPopoverEscapesScrollClipAndDismissesWithEscape() throws {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(PopoverProbe()), size: .init(width: 300, height: 200))
    renderer.mount()
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "Show")).id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "Dismiss"))
    XCTAssertTrue(renderer.input(event: 6, value: 27))
    XCTAssertNil(findNode(in: renderer.tree!, text: "Dismiss"))
  }
  func testGridSharesColumnWidthsAcrossRows() throws {
    let tree = makeTree(
      Grid {
        GridRow {
          Text("A")
          Text("longer")
        }
        GridRow {
          Text("longest label")
          Text("B")
        }
      }, size: .init(width: 400, height: 200))
    let texts = allNodes(tree).filter { $0.kind == .text }
    XCTAssertEqual(texts[0].frame.width, texts[2].frame.width)
    XCTAssertEqual(texts[1].frame.minX, texts[3].frame.minX)
  }
}
