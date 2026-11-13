import JavaScriptEventLoop
import JavaScriptKit
import SwiftUIRuntime

@MainActor private var browserRenderer: Renderer?

@MainActor public func runApp<A: App>(_ app: A) {
  JavaScriptEventLoop.installGlobalExecutor()
  guard let scene = app.body as? any _WindowScene else {
    fatalError("SwiftUIPort requires WindowGroup as the top-level Scene")
  }
  let document = JSObject.global.document.object!
  guard let host = document.getElementById!("swiftui-root").object else {
    fatalError("SwiftUIPort requires a #swiftui-root element")
  }
  document.title = .string(scene._windowTitle.isEmpty ? "SwiftUIPort" : scene._windowTitle)

  let backend = WebBackend(document: document, host: host)
  let renderer = Renderer(
    backend: backend,
    root: scene._makeRootView(),
    size: backend.size,
    layoutEngine: LayoutEngine(textMeasurer: backend.measureText)
  )
  renderer.usesCustomScrollIndicators = false
  browserRenderer = renderer
  backend.connect(renderer)
  renderer.mount()
}

extension App {
  public static func main() {
    runApp(Self())
  }
}
