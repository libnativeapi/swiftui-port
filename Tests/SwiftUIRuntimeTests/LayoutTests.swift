@testable import SwiftUIRuntime
import XCTest

final class LayoutTests: XCTestCase {
  private let metrics = TextMetrics.default

  func testTextUsesFakeMetrics() {
    let tree = makeTree(Text("hello"), size: Size(width: 400, height: 200))
    XCTAssertEqual(tree.kind, .text)
    XCTAssertEqual(tree.frame.width, 5 * metrics.characterWidth)
    XCTAssertEqual(tree.frame.height, metrics.lineHeight)
  }

  func testVStackMeasuresAndPlacesChildren() {
    let tree = makeTree(
      VStack(alignment: .leading, spacing: 4) {
        Text("A")
        Text("BB")
      },
      size: Size(width: 200, height: 200)
    )

    XCTAssertEqual(tree.kind, .container(.vertical))
    XCTAssertEqual(tree.children.count, 2)
    XCTAssertEqual(tree.children[0].frame, Rect(x: 0, y: 0, width: 8, height: 20))
    XCTAssertEqual(tree.children[1].frame, Rect(x: 0, y: 24, width: 16, height: 20))
  }

  func testVStackCentersChildrenOnCrossAxis() {
    let tree = makeTree(
      VStack(spacing: 0) {
        Text("A")
      },
      size: Size(width: 100, height: 100)
    )
    XCTAssertEqual(tree.children[0].frame, Rect(x: 46, y: 0, width: 8, height: 20))
  }

  func testHStackSpacerTakesLeftoverSpace() {
    let tree = makeTree(
      HStack(spacing: 0) {
        Text("A")
        Spacer()
        Text("B")
      },
      size: Size(width: 100, height: 20)
    )

    XCTAssertEqual(tree.children.count, 3)
    XCTAssertEqual(tree.children[0].frame, Rect(x: 0, y: 0, width: 8, height: 20))
    XCTAssertEqual(tree.children[1].kind, .spacer)
    XCTAssertEqual(tree.children[1].frame, Rect(x: 8, y: 0, width: 84, height: 20))
    XCTAssertEqual(tree.children[2].frame, Rect(x: 92, y: 0, width: 8, height: 20))
  }

  func testPaddingWrapsAndInsetsContent() {
    let tree = makeTree(
      Text("A").padding(10),
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(tree.kind, .padding)
    XCTAssertEqual(tree.children.count, 1)
    XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 100, height: 100))
    XCTAssertEqual(tree.children[0].frame, Rect(x: 10, y: 10, width: 8, height: 20))
  }

  func testFrameOverridesMeasuredSize() {
    let tree = makeTree(
      VStack(spacing: 0) {
        Text("A").frame(width: 40, height: 30)
      },
      size: Size(width: 100, height: 100)
    )
    XCTAssertEqual(tree.children[0].frame.width, 40)
    XCTAssertEqual(tree.children[0].frame.height, 30)
  }

  func testHiddenChildDoesNotOccupyStackSpace() {
    let tree = makeTree(
      VStack(spacing: 0) {
        Text("A")
        Text("B").hidden()
        Text("C")
      },
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(tree.children[1].props.visible, false)
    XCTAssertEqual(tree.children[1].frame, .zero)
    XCTAssertEqual(tree.children[2].frame, Rect(x: 46, y: 20, width: 8, height: 20))
  }

  func testForegroundColorIsInherited() {
    let tree = makeTree(
      VStack {
        Text("A")
      }
      .foregroundColor(.red),
      size: Size(width: 100, height: 100)
    )
    XCTAssertEqual(tree.children[0].props.foreground, .red)
  }

  func testDisabledIsInheritedAndCanBeOverridden() {
    let tree = makeTree(
      VStack {
        Button("A") {}
        Button("B") {}.disabled(false)
      }
      .disabled(),
      size: Size(width: 100, height: 100)
    )

    XCTAssertEqual(tree.children[0].props.enabled, false)
    XCTAssertEqual(tree.children[1].props.enabled, true)
  }
}
