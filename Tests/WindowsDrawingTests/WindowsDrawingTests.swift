import CSwiftUIWindowsTestSupport
import SwiftUIPort
import XCTest

final class WindowsDrawingTests: XCTestCase {
  func testScrollPixelReuseMatchesFreshRenderingAndFallsBackForUnsafeFrames() {
    WindowsDrawingBackend.prepareApplication()
    let result = scroll_probe()
    XCTAssertGreaterThanOrEqual(result.copies, 4)
    XCTAssertEqual(result.pixel_errors, 0, "Cached scroll pixels must exactly match a fresh render")
    XCTAssertEqual(
      result.fallback_errors, 0,
      "Backgrounds, overlays, content edits and fractional pixels must fall back")
  }
  func testHighDpiPixelsAndHoverDoNotRepositionControls() {
    WindowsDrawingBackend.prepareApplication()
    let result = drawing_probe()
    print("Windows drawing probe: \(result.dpi) DPI, \(result.hover_events) hover transitions")
    XCTAssertEqual(result.aware, 1, "Windows must use per-monitor V2 before creating HWNDs")
    XCTAssertGreaterThanOrEqual(result.dpi, 96)
    XCTAssertEqual(result.pixel_errors, 0, "The framebuffer must be copied at physical pixel size")
    XCTAssertEqual(
      result.child_pixel_errors, 0, "Owner-drawn controls must share the host's exact pixels")
    XCTAssertEqual(result.hover_events, 40)
    XCTAssertEqual(result.expose_errors, 0,
      "Full exposes must paint the canvas once and retain native-widget overlap paints")
    XCTAssertEqual(
      result.position_changes, 0, "Hover must not re-order or reset the region of a control")
    XCTAssertEqual(
      result.immediate_paints, 0, "Publishing a frame must not paint intermediate states")
    XCTAssertEqual(
      result.clip_errors, 0, "Clipping must recover when a control scrolls back into view")
    XCTAssertEqual(
      result.atomic_errors, 0, "A native paint during updates must see a complete frame")
    XCTAssertGreaterThan(result.damage_pixels, 0)
    XCTAssertLessThan(
      result.damage_pixels, result.surface_pixels / 2,
      "Hover should invalidate the button's ink, not the full window")
    XCTAssertEqual(
      result.scope_errors, 0, "Changing visible commands must repaint only their shared clip")
    XCTAssertEqual(
      result.group_errors, 0,
      "Nested scrolling must preserve pixels, native coordinates, activation and Tab order")
  }
}
