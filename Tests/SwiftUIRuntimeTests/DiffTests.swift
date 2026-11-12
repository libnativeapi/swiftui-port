@testable import SwiftUIRuntime
import XCTest

final class DiffTests: XCTestCase {
  func testMountCreatesEveryNode() {
    let tree = makeTree(
      VStack {
        Text("A")
        Button("B") {}
      },
      size: Size(width: 100, height: 100)
    )
    var allocator = NodeIDAllocator()
    var commands: [RenderCommand] = []
    let mounted = createSubtree(
      tree,
      parent: nil,
      index: 0,
      commands: &commands,
      allocator: &allocator
    )

    XCTAssertEqual(count(commands, where: \.isCreate), allNodes(mounted).count)
    XCTAssertEqual(count(commands, where: \.isInsert), allNodes(mounted).count)
    XCTAssertEqual(count(commands, where: \.isSetFrame), allNodes(mounted).count)
    guard case .create(let rootID, let rootKind, let rootProps)? = commands.first else {
      return XCTFail("first command should create the root")
    }
    XCTAssertEqual(rootID, mounted.id)
    XCTAssertEqual(rootKind, .container(.vertical))
    XCTAssertEqual(rootProps, mounted.props)
  }

  func testPropChangeOnlyEmitsSetProps() {
    let (_, _, commands) = diffTrees(
      old: Text("one"),
      new: Text("two"),
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isCreate), 0)
    XCTAssertEqual(count(commands, where: \.isRemove), 0)
    XCTAssertEqual(count(commands, where: \.isSetProps), 1)
    XCTAssertEqual(count(commands, where: \.isSetFrame), 0)
  }

  func testTextChangeAlsoMovesFrameWhenWidthChanges() {
    let (_, _, commands) = diffTrees(
      old: Text("a"),
      new: Text("abc"),
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isSetProps), 1)
    XCTAssertEqual(count(commands, where: \.isSetFrame), 1)
  }

  func testAppendInsertsWithoutRecreatingSiblings() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 0) {
        Text("a").id("a")
        Text("b").id("b")
      },
      new: VStack(spacing: 0) {
        Text("a").id("a")
        Text("b").id("b")
        Text("c").id("c")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isCreate), 1)
    XCTAssertEqual(count(commands, where: \.isInsert), 1)
    XCTAssertEqual(count(commands, where: \.isRemove), 0)
    XCTAssertEqual(count(commands, where: \.isMove), 0)
    XCTAssertEqual(count(commands, where: \.isSetProps), 0)
  }

  func testMiddleInsertKeepsExistingIdentity() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 0) {
        Text("a").id("a")
        Text("b").id("b")
      },
      new: VStack(spacing: 0) {
        Text("a").id("a")
        Text("x").id("x")
        Text("b").id("b")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isCreate), 1)
    XCTAssertEqual(count(commands, where: \.isInsert), 1)
    XCTAssertEqual(count(commands, where: \.isRemove), 0)
    XCTAssertEqual(count(commands, where: \.isMove), 0)
  }

  func testRemoveDropsOneSubtree() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 0) {
        Text("a").id("a")
        Text("x").id("x")
        Text("b").id("b")
      },
      new: VStack(spacing: 0) {
        Text("a").id("a")
        Text("b").id("b")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isRemove), 1)
    XCTAssertEqual(count(commands, where: \.isCreate), 0)
    XCTAssertEqual(count(commands, where: \.isMove), 0)
  }

  func testReorderEmitsMoveNotRecreate() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 0) {
        Text("a").id("a")
        Text("b").id("b")
        Text("c").id("c")
      },
      new: VStack(spacing: 0) {
        Text("b").id("b")
        Text("a").id("a")
        Text("c").id("c")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isMove), 1)
    XCTAssertEqual(count(commands, where: \.isCreate), 0)
    XCTAssertEqual(count(commands, where: \.isRemove), 0)
    XCTAssertEqual(count(commands, where: \.isSetProps), 0)
  }

  func testKindChangeReplacesTheNativeView() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 0) {
        Text("same").id("same")
      },
      new: VStack(spacing: 0) {
        Button("same") {}.id("same")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(count(commands, where: \.isRemove), 1)
    XCTAssertEqual(count(commands, where: \.isCreate), 1)
    XCTAssertEqual(count(commands, where: \.isInsert), 1)
  }

  func testUnchangedTreeEmitsNoCommands() {
    let (_, _, commands) = diffTrees(
      old: VStack(spacing: 4) {
        Text("a")
        Text("b")
      },
      new: VStack(spacing: 4) {
        Text("a")
        Text("b")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertTrue(commands.isEmpty, "expected no commands, got \(commands)")
  }
}
