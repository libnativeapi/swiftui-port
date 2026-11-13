/// A top-level container of windows.
///
/// v0.1 only provides ``WindowGroup``; the protocol exists so an app's `body`
/// has the same shape as SwiftUI's `some Scene`.

/// A scene that presents nothing.

/// The entry point of a SwiftUIPort application.
///
/// ```swift
/// @main
/// struct CounterApp: App {
///   var body: some Scene {
///     WindowGroup("Counter") { CounterView() }
///   }
/// }
/// ```
///
/// The `@main` support is supplied by `SwiftUIPort`, which builds the native
/// window and runs the platform application loop.

/// A window whose content is the given view.
///
/// `title` becomes the native window title. v0.1 creates one window per
/// WindowGroup and treats an empty title as "SwiftUIPort".

/// The bridge the native runner uses to obtain a root view and title.
///
/// Public because `SwiftUIPort` lives in another module; the underscore marks
/// it as implementation detail, not user API.

public protocol Scene {
  associatedtype Body: Scene

  @SceneBuilder var body: Body { get }
}
@resultBuilder
public enum SceneBuilder {
  public static func buildBlock() -> EmptyScene {
    EmptyScene()
  }

  public static func buildBlock<S: Scene>(_ scene: S) -> S {
    scene
  }
}
public struct EmptyScene: Scene {
  public typealias Body = EmptyScene

  public init() {}

  public var body: EmptyScene { EmptyScene() }
}
@MainActor @preconcurrency public protocol App {
  associatedtype Body: Scene

  @SceneBuilder var body: Body { get }

  init()
}
public struct WindowGroup<Content: View>: Scene {
  public typealias Body = EmptyScene

  public let title: String
  public var _defaultSize = Size(width: 480, height: 320)
  private let content: () -> Content

  public init(
    _ title: String = "",
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.content = content
  }

  public var body: EmptyScene { EmptyScene() }
  public func defaultSize(width: Double, height: Double) -> Self {
    var copy = self
    copy._defaultSize = Size(width: width, height: height)
    return copy
  }

}
public protocol _WindowScene {
  var _windowTitle: String { get }
  var _defaultSize: Size { get }
  func _makeRootView() -> AnyView
}
extension WindowGroup: _WindowScene {
  public var _windowTitle: String { title }

  public func _makeRootView() -> AnyView {
    AnyView(content())
  }
}
