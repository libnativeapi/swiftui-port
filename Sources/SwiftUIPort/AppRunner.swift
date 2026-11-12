import Foundation
import NativeAPI
import SwiftUIRuntime

/// Runs an app: create the native window, mount the scene's root view, and
/// enter the platform application loop.
///
/// v0.1 supports one `WindowGroup`. The window is sized 480×320 by default and
/// closes through the platform's normal window-close path.
public func runApp<A: App>(_ app: A) {
  let scene = app.body
  guard let windowScene = scene as? any _WindowScene else {
    fatalError("SwiftUIPort v0.1 requires WindowGroup as the top-level Scene")
  }

  guard let window = NativeAPI.Window.create() else {
    fatalError("nativeapi failed to create a window")
  }

  let title = windowScene._windowTitle
  window.setTitle(title.isEmpty ? "SwiftUIPort" : title)

  let initialWidth = 480.0
  let initialHeight = 320.0
  window.setContentSize(NativeAPI.Size(width: initialWidth, height: initialHeight))

  guard let backend = NativeViewBackend(window: window) else {
    fatalError("nativeapi window has no content view")
  }

  let renderer = Renderer(
    backend: backend,
    root: windowScene._makeRootView(),
    size: SwiftUIRuntime.Size(width: initialWidth, height: initialHeight)
  )
  backend.onResize = { [weak renderer] size in
    renderer?.resize(to: size)
  }
  renderer.mount()
  window.show()

  if CommandLine.arguments.contains("--smoke") {
    startSmokeTimer()
  }

  _ = NativeAPI.Application.shared.runWithWindow(window)
}

/// `--smoke` opens the window and asks the application to quit a few seconds
/// later, which is what CI uses to prove the window and event loop work.
private func startSmokeTimer() {
  Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 3)
    NativeAPI.Application.shared.quit(0)
  }
}

public extension App {
  /// The `@main` entry point. `SwiftUI` re-exports this extension, so an app
  /// only needs `import SwiftUI`.
  static func main() {
    runApp(Self())
  }
}
