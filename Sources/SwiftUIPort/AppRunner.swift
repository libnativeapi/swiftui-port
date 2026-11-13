import Foundation

import NativeAPI

/// Runs an app: create the native window, mount the scene's root view, and
/// enter the platform application loop.
///
/// v0.1 supports one `WindowGroup`. The window is sized 480×320 by default and
/// closes through the platform's normal window-close path.
import SwiftUIRuntime

/// `--smoke` opens the window and asks the application to quit a few seconds
/// later, which is what CI uses to prove the window and event loop work.

public func runApp<A: App>(_ app: A) {
  #if os(Windows)
    WindowsDrawingBackend.prepareApplication()
  #endif
  let scene = app.body
  guard let windowScene = scene as? any _WindowScene else {
    fatalError("SwiftUIPort v0.1 requires WindowGroup as the top-level Scene")
  }

  // Touching the application singleton runs the platform initialization
  // (gtk_init on Linux, COM/UI-thread setup on Windows) before the first window
  // is created. Creating a GTK window before that fails with "No display
  // available".
  let application = NativeAPI.Application.shared
  _ = application.isRunning()

  guard let window = NativeAPI.Window.create() else {
    fatalError("nativeapi failed to create a window")
  }

  let title = windowScene._windowTitle
  window.setTitle(title.isEmpty ? "SwiftUIPort" : title)

  let initialWidth = windowScene._defaultSize.width
  let initialHeight = windowScene._defaultSize.height
  window.setContentSize(NativeAPI.Size(width: initialWidth, height: initialHeight))

  #if os(Windows)
    guard let backend = WindowsDrawingBackend(window: window, schedulesUpdates: true) else {
      fatalError("Could not attach the Windows drawing backend")
    }
    let layout = LayoutEngine(textMeasurer: WindowsDrawingBackend.measureText)
  #else
    guard let backend = NativeViewBackend(window: window) else {
      fatalError("nativeapi window has no content view")
    }
    let layout = LayoutEngine()
  #endif

  let renderer = Renderer(
    backend: backend,
    root: windowScene._makeRootView(),
    size: SwiftUIRuntime.Size(width: initialWidth, height: initialHeight),
    layoutEngine: layout
  )
  backend.onResize = { [weak renderer] size in
    renderer?.resize(to: size)
  }
  #if os(Windows)
    backend.inputHandler = { [weak renderer] id, event, point, value, modifiers, text in
      renderer?.input(
        id: id, event: event, point: point, value: value, modifiers: modifiers, text: text) ?? false
    }
    backend.interactionHandler = { [weak renderer] id, interaction in
      renderer?.interact(id, interaction)
    }
  #endif
  renderer.mount()
  if let path = ProcessInfo.processInfo.environment["SWIFTUI_PORT_TREE_PATH"],
    let tree = renderer.tree
  {
    func encode(_ node: Element) -> [String: Any] {
      [
        "kind": node.kind.description, "text": node.props.text, "id": node.id.rawValue,
        "x": node.frame.minX, "y": node.frame.minY, "width": node.frame.width,
        "height": node.frame.height, "children": node.children.map(encode),
      ]
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: encode(tree), options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }
  window.show()
  #if os(Windows)
    backend.focusInitialControl()
  #endif

  // A tiling compositor may size the window after the first map. Pick up the
  // actual content area once it exists; later resizes arrive through the
  // window listener.
  let shownSize = window.contentSize
  if shownSize.width > 0, shownSize.height > 0 {
    renderer.resize(
      to: SwiftUIRuntime.Size(width: shownSize.width, height: shownSize.height)
    )
  }

  if CommandLine.arguments.contains("--smoke") {
    startSmokeTimer()
  }

  withExtendedLifetime(renderer) { _ = application.runWithWindow(window) }
}
private func startSmokeTimer() {
  Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 3)
    NativeAPI.Application.shared.quit(0)
  }
}
extension App {
  /// The `@main` entry point. `SwiftUI` re-exports this extension, so an app
  /// only needs `import SwiftUI`.
  public static func main() {
    #if os(Windows)
      WindowsDrawingBackend.prepareApplication()
    #endif
    runApp(Self())
  }
}
