import XCTest
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

@testable import SwiftUIRuntime

final class IncrementalRenderingTests: XCTestCase {
  private struct GridWidthControl: View {
    @State private var wide = false
    var body: some View {
      Button("Resize column") { wide.toggle() }
        .frame(width: wide ? 180 : 100, height: 40)
    }
  }
  private struct RetainedGridRow: View {
    var body: some View {
      Grid {
        GridRow {
          GridWidthControl()
          Color.clear.frame(width: 60, height: 40)
        }
        GridRow {
          GeometryReader { proxy in
            Rectangle().fill(Color.black).opacity(0.4)
              .frame(width: proxy.size.width * 0.6, height: 2)
          }.frame(height: 40)
          Color.blue.frame(width: 60, height: 40)
        }
      }
    }
  }
  func testRetainedGridRowReconcilesRebuiltGeometryChildren() throws {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(RetainedGridRow()),
      size: Size(width: 300, height: 200))
    renderer.mount()
    let initial = allNodes(try XCTUnwrap(renderer.tree))
    let ink = try XCTUnwrap(initial.first { $0.kind == .shape && $0.props.opacity == 0.4 })
    let control = try XCTUnwrap(findNode(in: renderer.tree!, text: "Resize column"))
    for _ in 0..<4 {
      renderer.performTap(control.id)
      let nodes = allNodes(try XCTUnwrap(renderer.tree))
      XCTAssertFalse(
        nodes.contains { $0.id.rawValue == 0 }, "Every rebuilt geometry child must be mounted")
      XCTAssertEqual(Set(nodes.map(\.id)).count, nodes.count)
      XCTAssertEqual(
        nodes.first { $0.kind == .shape && $0.props.opacity == 0.4 }?.id, ink.id,
        "Relayout must preserve the ink's animation identity")
    }
  }

  func testOverflowAndClippingHitTestingAfterRelayout() throws {
    for clipped in [false, true] {
      StateRegistry.shared.reset()
      var taps = 0
      let content = Button("overflow") { taps += 1 }
        .frame(width: 80, height: 40).offset(x: 120)
        .frame(width: 80, height: 40)
      let renderer = Renderer(
        backend: FakeBackend(),
        root: clipped ? AnyView(content.clipped()) : AnyView(content),
        size: Size(width: 300, height: 200))
      renderer.mount()
      for width in [300.0, 400.0] {
        renderer.resize(to: Size(width: width, height: 200))
        let target = try XCTUnwrap(findNode(in: renderer.tree!, text: "overflow"))
        let point = CGPoint(x: target.frame.minX + 10, y: target.frame.minY + 10)
        renderer.input(event: 2, point: point)
        renderer.input(event: 3, point: point)
      }
      XCTAssertEqual(taps, clipped ? 0 : 2)
    }
  }
  private final class Counts {
    var bodies: [String: Int] = [:]
    var appearances = 0, disappearances = 0
  }
  private struct Counter: View {
    let name: String
    let counts: Counts
    @State private var count = 0
    var body: some View {
      let _ = counts.bodies[name, default: 0] += 1
      Button("\(name):\(count)") { count += 1 }
        .onAppear { counts.appearances += 1 }
        .onDisappear { counts.disappearances += 1 }
    }
  }

  private struct CollidingID: Hashable {
    let name: String
    func hash(into hasher: inout Hasher) { hasher.combine(0) }
  }

  private struct CollidingRows: View {
    let counts: Counts
    @State private var reversed = false

    var body: some View {
      let names = reversed ? ["second", "first"] : ["first", "second"]
      VStack {
        Button("Reverse") { reversed.toggle() }
        ForEach(names.map { CollidingID(name: $0) }, id: \.self) { item in
          Counter(name: item.name, counts: counts)
        }
      }
    }
  }

  func testCollidingCollectionIDsRetainIndependentStateAfterReordering() throws {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(CollidingRows(counts: Counts())),
      size: Size(width: 300, height: 200))
    renderer.mount()
    let first = try XCTUnwrap(findNode(in: renderer.tree!, text: "first:0"))
    let reverse = try XCTUnwrap(findNode(in: renderer.tree!, text: "Reverse"))
    renderer.performTap(first.id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "second:0"))
    renderer.performTap(reverse.id)
    XCTAssertEqual(findNode(in: renderer.tree!, text: "first:1")?.id, first.id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "second:0"))
  }
  private struct Family: View {
    let counts: Counts
    @State private var show = true
    var body: some View {
      VStack {
        Counter(name: "A", counts: counts)
        if show { Counter(name: "B", counts: counts) }
        Button("Remove") { show = false }
      }
    }
  }
  func testLocalStateRetainsUnrelatedBodiesStateAndLifecycle() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(Family(counts: counts)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    let a = try XCTUnwrap(findNode(in: renderer.tree!, text: "A:0"))
    let b = try XCTUnwrap(findNode(in: renderer.tree!, text: "B:0"))
    renderer.performTap(a.id)
    renderer.performTap(a.id)
    XCTAssertEqual(counts.bodies["A"], 3)
    XCTAssertEqual(counts.bodies["B"], 1, "A sibling body must not run for local state")
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "A:2"))
    renderer.performTap(b.id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "A:2"))
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "B:1"))
    XCTAssertEqual(counts.appearances, 2)
    XCTAssertEqual(counts.disappearances, 0)
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "Remove")).id)
    XCTAssertEqual(counts.disappearances, 1)
  }
  private struct Batch: View {
    let counts: Counts
    @State private var first = 0
    @State private var second = 0
    var body: some View {
      let _ = counts.bodies["batch", default: 0] += 1
      Button("\(first):\(second)") {
        first += 1
        second += 1
      }
    }
  }
  func testOneActionPublishesOneRenderForMultipleStateWrites() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(Batch(counts: counts)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "0:0")).id)
    XCTAssertEqual(counts.bodies["batch"], 2)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "1:1"))
  }
  func testSameExplicitIdentityInDifferentParentsKeepsDistinctHandles() throws {
    let renderer = Renderer(
      backend: FakeBackend(),
      root: AnyView(
        HStack {
          VStack { Text("Left").id(1) }
          VStack { Text("Right").id(1) }
        }
      ), size: Size(width: 300, height: 200))
    renderer.mount()
    let left = try XCTUnwrap(findNode(in: renderer.tree!, text: "Left"))
    let right = try XCTUnwrap(findNode(in: renderer.tree!, text: "Right"))
    XCTAssertNotEqual(left.id, right.id)
    renderer.resize(to: Size(width: 400, height: 300))
    XCTAssertEqual(findNode(in: renderer.tree!, text: "Left")?.id, left.id)
    XCTAssertEqual(findNode(in: renderer.tree!, text: "Right")?.id, right.id)
  }
  func testRepeatedLayoutProposalsMeasureTextOncePerPass() {
    StateRegistry.shared.reset()
    var measures = 0
    let engine = LayoutEngine(textMeasurer: { text, _ in
      measures += 1
      return Size(width: Double(text.count * 8), height: 16)
    })
    var view = AnyView(Text("memoized"))
    for _ in 0..<30 { view = AnyView(view.frame(width: 100, height: 20)) }
    let renderer = Renderer(
      backend: FakeBackend(), root: view,
      size: Size(width: 300, height: 200), layoutEngine: engine)
    renderer.mount()
    XCTAssertLessThanOrEqual(measures, 8, "Identical proposals must reuse measurements")
    let before = measures
    renderer.resize(to: Size(width: 400, height: 300))
    XCTAssertGreaterThanOrEqual(measures, before)
    XCTAssertLessThanOrEqual(measures - before, 8)
  }
  private struct Resizable: View {
    @State private var expanded = false
    var body: some View {
      Button("Resize") { expanded.toggle() }
        .frame(width: expanded ? 120 : 60, height: 30)
    }
  }
  func testUnchangedSiblingMovesWhenNeighborChangesSize() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let renderer = Renderer(
      backend: FakeBackend(),
      root: AnyView(
        HStack(spacing: 0) {
          Resizable()
          Counter(name: "Neighbor", counts: counts)
        }), size: Size(width: 400, height: 200))
    renderer.mount()
    let neighbor = try XCTUnwrap(findNode(in: renderer.tree!, text: "Neighbor:0"))
    let resize = try XCTUnwrap(findNode(in: renderer.tree!, text: "Resize"))
    renderer.performTap(resize.id)
    let moved = try XCTUnwrap(findNode(in: renderer.tree!, text: "Neighbor:0"))
    XCTAssertEqual(counts.bodies["Neighbor"], 1)
    XCTAssertEqual(moved.id, neighbor.id)
    XCTAssertEqual(moved.frame.minX, neighbor.frame.minX + 60)
    XCTAssertTrue(
      renderer.lastCommands.contains {
        if case .setFrame(let id, _) = $0 { return id == neighbor.id }
        return false
      })
    renderer.performTap(neighbor.id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "Neighbor:1"))
  }
  func testCachedSubtreeReflowsWhenWindowResizes() throws {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(),
      root: AnyView(Text("Centered").frame(maxWidth: .infinity, maxHeight: .infinity)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    let before = try XCTUnwrap(findNode(in: renderer.tree!, text: "Centered"))
    renderer.resize(to: Size(width: 500, height: 400))
    let after = try XCTUnwrap(findNode(in: renderer.tree!, text: "Centered"))
    XCTAssertEqual(after.id, before.id)
    XCTAssertEqual(after.frame.minX, before.frame.minX + 100)
    XCTAssertEqual(after.frame.minY, before.frame.minY + 100)
    renderer.resize(to: Size(width: 300, height: 200))
    XCTAssertEqual(findNode(in: renderer.tree!, text: "Centered")?.frame, before.frame)
  }
  private final class ExternalModel { var text = "before" }
  private struct ExternalView: View {
    let model: ExternalModel
    var body: some View { Text(model.text) }
  }
  func testExplicitHostInvalidationReevaluatesUntrackedInputs() {
    StateRegistry.shared.reset()
    let model = ExternalModel()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(ExternalView(model: model)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    model.text = "after"
    renderer.setNeedsRender()
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "after"))
  }
  private struct GeometryFamily: View {
    let counts: Counts
    var body: some View {
      VStack {
        Counter(name: "outside", counts: counts)
        GeometryReader { proxy in
          let _ = counts.bodies["geometry", default: 0] += 1
          if proxy.size.width > 150 { Counter(name: "inside", counts: counts) }
        }
      }
    }
  }
  func testGeometryReuseRetainsStateAndLifecycleAndReflowsOnResize() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(GeometryFamily(counts: counts)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "outside:0")).id)
    XCTAssertEqual(counts.bodies["geometry"], 1)
    XCTAssertEqual(counts.appearances, 2)
    XCTAssertEqual(counts.disappearances, 0)
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "inside:0")).id)
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "outside:1")).id)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "inside:1"))
    XCTAssertEqual(counts.appearances, 2)
    renderer.resize(to: Size(width: 100, height: 200))
    XCTAssertNil(findNode(in: renderer.tree!, text: "inside:1"))
    XCTAssertEqual(counts.disappearances, 1)
  }
  private struct PositionedGeometry: View {
    let global: Bool
    let counts: Counts
    var body: some View {
      ScrollView {
        GeometryReader { proxy in
          let _ = counts.bodies["geometry", default: 0] += 1
          Text(global ? String(Int(proxy.frame(in: .global).minY)) : "size only")
        }.frame(height: 600)
      }
    }
  }
  private struct ScrollingCounter: View {
    let counts: Counts
    var body: some View {
      ScrollView {
        VStack {
          Counter(name: "scrolling", counts: counts)
          Text("tail").frame(height: 600)
        }
      }
    }
  }
  private final class PublicationBackend: RenderBackend {
    var tapHandler: ((NodeID) -> Void)?
    var publications = 0
    var commands: [RenderCommand] = []
    var scrollViewport: Rect?
    func perform(_ commands: [RenderCommand]) { self.commands = commands }
    func didRender(_ root: Element) { publications += 1 }
    func didScroll(_ root: Element, viewport: Rect) {
      scrollViewport = viewport
      didRender(root)
    }
  }

  func testGridScrollReportsOnlyItsViewport() throws {
    StateRegistry.shared.reset()
    let backend = PublicationBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(
        VStack(spacing: 0) {
          Text("Header").frame(height: 40)
          ScrollView {
            LazyVGrid(columns: [GridItem(.fixed(100))]) {
              ForEach(0..<10) { Text("Grid row \($0)").frame(width: 100, height: 48) }
            }
          }
        }), size: Size(width: 240, height: 180))
    renderer.mount()
    let gridRow = try XCTUnwrap(findNode(in: renderer.tree!, text: "Grid row 1"))
    let viewport = try XCTUnwrap(findNode(in: renderer.tree!, kind: .scroll)?.frame)
    renderer.input(event: 5, point: CGPoint(x: 120, y: 70), value: -120)
    let updated = try XCTUnwrap(findNode(in: renderer.tree!, text: "Grid row 1"))
    XCTAssertEqual(backend.scrollViewport, viewport)
    XCTAssertEqual(updated.id, gridRow.id)
    XCTAssertEqual(updated.frame.minY, gridRow.frame.minY - 48, accuracy: 0.0001)
    XCTAssertEqual(findNode(in: renderer.tree!, text: "Header")?.frame.minY, 10)
  }
  private final class DeferredBackend: RenderBackend {
    var tapHandler: ((NodeID) -> Void)?
    var transactionHandler: ((() -> Void) -> Void)?
    var pending: (() -> Void)?
    var publications = 0
    func perform(_ commands: [RenderCommand]) {}
    func didRender(_ root: Element) { publications += 1 }
    func requestRender(_ render: @escaping () -> Void) -> Bool {
      pending = render
      return true
    }
    func flush() {
      let action = pending
      pending = nil
      action?()
    }
  }
  func testDeferredWheelAccumulatesAndReversesBeforePublication() throws {
    StateRegistry.shared.reset()
    let backend = DeferredBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(ScrollView { Text("tail").frame(height: 600) }),
      size: Size(width: 300, height: 120))
    renderer.mount()
    let initialY = try XCTUnwrap(findNode(in: renderer.tree!, text: "tail")).frame.minY
    let point = CGPoint(x: 150, y: 24)
    for delta in [-30, -30, -30, 30] { renderer.input(event: 5, point: point, value: delta) }
    XCTAssertEqual(backend.publications, 1)
    backend.flush()
    XCTAssertEqual(backend.publications, 2)
    XCTAssertEqual(
      try XCTUnwrap(findNode(in: renderer.tree!, text: "tail")).frame.minY, initialY - 24)
    for _ in 0..<3 { renderer.input(event: 5, point: point, value: 30) }
    backend.flush()
    XCTAssertEqual(try XCTUnwrap(findNode(in: renderer.tree!, text: "tail")).frame.minY, initialY)
  }
  func testBatchedScrollResolvesOnlyFinalHoverPath() throws {
    StateRegistry.shared.reset()
    let backend = DeferredBackend()
    var events: [String] = []
    let renderer = Renderer(
      backend: backend,
      root: AnyView(HoverRows { events.append("\($0):\($1)") }),
      size: Size(width: 300, height: 120))
    renderer.mount()
    backend.transactionHandler? {
      for _ in 0..<4 { renderer.input(event: 5, point: CGPoint(x: 150, y: 24), value: -30) }
    }
    XCTAssertEqual(events, ["second:true", "parent:true"])
    backend.flush()
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "second hot"))
    XCTAssertEqual(backend.publications, 2)
  }
  private struct HoverRows: View {
    var changesSize = false
    let transitions: (String, Bool) -> Void
    @State private var first = false
    @State private var second = false
    var body: some View {
      ScrollView {
        VStack(spacing: 0) {
          Button(first ? "first hot" : "first") {}.frame(height: 48)
            .onHover {
              first = $0
              transitions("first", $0)
            }
          Button(second ? "second hot" : "second") {}
            .frame(height: second && changesSize ? 96 : 48)
            .onHover {
              second = $0
              transitions("second", $0)
            }
          Text("tail").frame(height: 400)
        }.overlay(Rectangle().stroke(.red, lineWidth: 1))
          .onHover { transitions("parent", $0) }
      }
    }
  }
  func testScrollAndHoverPublishOnceAndIgnoreLateNativeNotifications() throws {
    StateRegistry.shared.reset()
    let backend = PublicationBackend()
    var events: [String] = []
    let renderer = Renderer(
      backend: backend,
      root: AnyView(
        HoverRows {
          events.append("\($0):\($1)")
        }), size: Size(width: 300, height: 120))
    renderer.mount()
    renderer.input(event: 1, point: CGPoint(x: 150, y: 24))
    let first = try XCTUnwrap(findNode(in: renderer.tree!, text: "first hot"))
    let before = backend.publications
    renderer.input(event: 5, point: CGPoint(x: 150, y: 24), value: -120)
    XCTAssertEqual(backend.publications, before + 1)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "second hot"))
    XCTAssertEqual(events, ["first:true", "parent:true", "first:false", "second:true"])
    let second = try XCTUnwrap(findNode(in: renderer.tree!, text: "second hot"))
    // A text node and its native button describe the same hover ancestry.
    renderer.interact(first.id, .hover(false))
    renderer.interact(second.id, .hover(true))
    renderer.interact(second.id, .hover(true))
    XCTAssertEqual(backend.publications, before + 1)
    XCTAssertEqual(events.count, 4)
  }
  func testCombinedScrollAndHoverRelayoutKeepsBackendFramesConsistent() throws {
    StateRegistry.shared.reset()
    let backend = PublicationBackend()
    let renderer = Renderer(
      backend: backend,
      root: AnyView(HoverRows(changesSize: true) { _, _ in }),
      size: Size(width: 300, height: 120))
    renderer.mount()
    renderer.input(event: 1, point: CGPoint(x: 150, y: 24))
    var nativeFrames = Dictionary(
      uniqueKeysWithValues: allNodes(renderer.tree!).map { ($0.id, $0.frame) })
    let before = backend.publications
    renderer.input(event: 5, point: CGPoint(x: 150, y: 24), value: -120)
    XCTAssertEqual(backend.publications, before + 1)
    XCTAssertNotNil(findNode(in: renderer.tree!, text: "second hot"))
    for command in backend.commands {
      if case .setFrame(let id, let frame) = command { nativeFrames[id] = frame }
    }
    let frames = Dictionary(
      uniqueKeysWithValues: allNodes(renderer.tree!).map { ($0.id, $0.frame) })
    XCTAssertEqual(nativeFrames, frames)
    renderer.setNeedsRender()
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: allNodes(renderer.tree!).map { ($0.id, $0.frame) }), frames)
  }
  private struct PositionedLayout: Layout {
    let positionSensitive: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      CGSize(width: proposal.width ?? 300, height: 600)
    }
    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      let adjustment = positionSensitive ? abs(bounds.minY).truncatingRemainder(dividingBy: 70) : 0
      subviews.first?.place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + adjustment),
        proposal: ProposedViewSize(width: bounds.width, height: 600))
    }
  }
  func testCustomLayoutScrollVerifiesPlacementAndClosedPopoverDoesNotBlockIt() throws {
    for sensitive in [false, true] {
      StateRegistry.shared.reset()
      let content = ScrollView {
        PositionedLayout(positionSensitive: sensitive) { Text("position").frame(height: 600) }
      }.popover(isPresented: .constant(false)) { Text("closed") }
      let renderer = Renderer(
        backend: FakeBackend(), root: AnyView(content),
        size: Size(width: 300, height: 200))
      renderer.mount()
      let before = try XCTUnwrap(findNode(in: renderer.tree!, text: "position")).frame
      renderer.input(event: 5, point: CGPoint(x: 50, y: 50), value: -120)
      let after = try XCTUnwrap(findNode(in: renderer.tree!, text: "position")).frame
      XCTAssertEqual(after.minY, before.minY - (sensitive ? 0 : 48), accuracy: 0.001)
      XCTAssertEqual(renderer.lastTimings["scroll.translate"] != nil, !sensitive)
      renderer.setNeedsRender()
      XCTAssertEqual(findNode(in: renderer.tree!, text: "position")?.frame, after)
    }
  }
  func testScrollKeepsActionsStateAndCoordinatesAcrossFullUpdates() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(ScrollingCounter(counts: counts)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    let initial = try XCTUnwrap(findNode(in: renderer.tree!, text: "scrolling:0"))
    for _ in 0..<3 { renderer.input(event: 5, point: CGPoint(x: 50, y: 50), value: -120) }
    XCTAssertEqual(counts.bodies["scrolling"], 1)
    XCTAssertEqual(counts.appearances, 1)
    let scrolled = try XCTUnwrap(findNode(in: renderer.tree!, text: "scrolling:0"))
    XCTAssertEqual(scrolled.frame.minY, initial.frame.minY - 144, accuracy: 0.001)
    renderer.performTap(scrolled.id)
    let updated = try XCTUnwrap(findNode(in: renderer.tree!, text: "scrolling:1"))
    XCTAssertEqual(updated.id, initial.id)
    XCTAssertEqual(updated.frame, scrolled.frame)
    renderer.setNeedsRender()
    XCTAssertEqual(findNode(in: renderer.tree!, text: "scrolling:1")?.frame, updated.frame)
    renderer.resize(to: Size(width: 300, height: 800))
    XCTAssertEqual(findNode(in: renderer.tree!, kind: .scroll)?.props.scrollOffset, .zero)
    XCTAssertEqual(counts.appearances, 1)
    XCTAssertEqual(counts.disappearances, 0)
  }
  func testScrollReevaluatesGlobalGeometryButRetainsSizeOnlyGeometry() throws {
    for global in [false, true] {
      StateRegistry.shared.reset()
      let counts = Counts()
      let renderer = Renderer(
        backend: FakeBackend(), root: AnyView(PositionedGeometry(global: global, counts: counts)),
        size: Size(width: 300, height: 200))
      renderer.mount()
      renderer.input(event: 5, point: CGPoint(x: 50, y: 50), value: -120)
      XCTAssertEqual(counts.bodies["geometry"], global ? 2 : 1)
      XCTAssertNotNil(findNode(in: renderer.tree!, text: global ? "-48" : "size only"))
    }
  }
  private struct NamedGeometry: View {
    var body: some View {
      ScrollView {
        GeometryReader { proxy in
          Text("named:\(Int(proxy.frame(in: .named("viewport")).minY))")
        }.frame(height: 600)
      }.coordinateSpace(name: "viewport")
    }
  }
  func testNamedCoordinateSpaceTracksScrollTranslation() {
    StateRegistry.shared.reset()
    let renderer = Renderer(
      backend: FakeBackend(), root: AnyView(NamedGeometry()),
      size: Size(width: 300, height: 200))
    renderer.mount()
    for offset in [48, 96, 144] {
      renderer.input(event: 5, point: CGPoint(x: 50, y: 50), value: -120)
      XCTAssertNotNil(findNode(in: renderer.tree!, text: "named:\(-offset)"))
    }
  }
  private struct EscapedGeometry: View {
    let counts: Counts
    let model: ExternalModel
    var body: some View {
      ScrollView {
        GeometryReader { proxy in
          let _ = counts.bodies["geometry", default: 0] += 1
          Button("Read frame") { model.text = String(Int(proxy.frame(in: .global).minY)) }
        }.frame(height: 600)
      }
    }
  }
  func testEscapedGeometryProxySeesCurrentCoordinatesAfterCachedTranslation() throws {
    StateRegistry.shared.reset()
    let counts = Counts()
    let model = ExternalModel()
    let renderer = Renderer(
      backend: FakeBackend(),
      root: AnyView(EscapedGeometry(counts: counts, model: model)),
      size: Size(width: 300, height: 200))
    renderer.mount()
    renderer.input(event: 5, point: CGPoint(x: 50, y: 50), value: -120)
    XCTAssertEqual(counts.bodies["geometry"], 1)
    renderer.performTap(try XCTUnwrap(findNode(in: renderer.tree!, text: "Read frame")).id)
    XCTAssertEqual(model.text, "-48")
  }
}
