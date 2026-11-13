// swift-tools-version:5.9

import Foundation
import PackageDescription

// SwiftUIPort — a declarative SwiftUI-shaped API over nativeapi's native views.
// Unofficial; not affiliated with Apple.
//
// The package is organized into these modules:
//   SwiftUIRuntime  engine: view protocol, element tree, layout, diff, state.
//                   No nativeapi dependency, so it builds and tests on macOS.
//   SwiftUIPort     the nativeapi backend and app/window integration.
//   SwiftUIWeb      the WebAssembly backend and browser integration.
//   SwiftUI         the user-facing facade (`import SwiftUI`).
//
// The desktop macOS build contains SwiftUIRuntime, its tests, and Counter
// compiled against Apple's SwiftUI. The WebAssembly build uses the port's
// SwiftUI facade on every supported host.
//
// The nativeapi Swift package is consumed as a sibling checkout at
// ../nativeapi/bindings/swift (see README "Requirements"). It is intentionally
// a path dependency: this project is not published to a package registry.

// SwiftPM evaluates the manifest on the host. Select the browser dependency
// graph explicitly so a cross-build never resolves desktop SDK dependencies.
let buildForWeb = ProcessInfo.processInfo.environment["SWIFTUI_PORT_WEB"] == "1"
var packageDependencies: [Package.Dependency] = []
if buildForWeb {
  packageDependencies = [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.63.0")
  ]
}
#if !os(macOS)
if !buildForWeb {
  packageDependencies = [
    .package(
      name: "NativeAPI",
      path: ProcessInfo.processInfo.environment["NATIVEAPI_SWIFT_PATH"]
        ?? "../nativeapi/bindings/swift")
  ]
}
#endif

var targets: [Target] = [
  .target(
    name: "SwiftUIRuntime",
    linkerSettings: [
      // Deep declarative view trees exceed Windows' 1 MiB default in debug builds.
      .unsafeFlags(["-Xlinker", "/STACK:16777216"], .when(platforms: [.windows]))
    ])
]

#if os(Windows)
if !buildForWeb {
  targets.append(
    .target(
      name: "CSwiftUIWindows", dependencies: [.product(name: "CNativeAPI", package: "NativeAPI")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedLibrary("gdiplus"), .linkedLibrary("comctl32")]))
  targets.append(
    .target(
      name: "CSwiftUIWindowsTestSupport", dependencies: ["CSwiftUIWindows"],
      path: "Tests/CSwiftUIWindowsTestSupport", publicHeadersPath: "include"))
  targets.append(
    .testTarget(
      name: "WindowsDrawingTests", dependencies: ["CSwiftUIWindowsTestSupport", "SwiftUIPort"]))
}
let drawingDependencies: [Target.Dependency] = ["CSwiftUIWindows"]
#elseif !os(macOS)
let drawingDependencies: [Target.Dependency] = []
#endif

var products: [Product] = [
  .library(name: "SwiftUIRuntime", targets: ["SwiftUIRuntime"])
]
var counterDependencies: [Target.Dependency] = []
if buildForWeb {
  targets += [
    .target(
      name: "SwiftUIWeb",
      dependencies: [
        "SwiftUIRuntime",
        .product(name: "JavaScriptKit", package: "JavaScriptKit"),
        .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
      ]
    ),
    .target(name: "SwiftUI", dependencies: ["SwiftUIRuntime", "SwiftUIWeb"]),
  ]
  products.append(.library(name: "SwiftUI", targets: ["SwiftUI"]))
  counterDependencies = ["SwiftUI"]
}

#if !os(macOS)
if !buildForWeb {
  targets += [
    .target(
      name: "SwiftUIPort",
      dependencies: [
        "SwiftUIRuntime",
        .product(name: "NativeAPI", package: "NativeAPI"),
      ] + drawingDependencies
    ),
    .target(
      name: "SwiftUI",
      dependencies: ["SwiftUIRuntime", "SwiftUIPort"]
    ),
  ]
  products += [
    .library(name: "SwiftUIPort", targets: ["SwiftUIPort"]),
    .library(name: "SwiftUI", targets: ["SwiftUI"]),
  ]
  counterDependencies = ["SwiftUI"]
}
#endif

targets.append(
  .executableTarget(
    name: "Counter",
    dependencies: counterDependencies,
    path: "Examples/Counter",
    linkerSettings: [
      // The WASI linker defaults to a 64 KiB stack. Debug view evaluation can
      // exceed it before the first frame has been mounted.
      .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"], .when(platforms: [.wasi]))
    ]
  )
)
targets.append(
  .testTarget(
    name: "SwiftUIRuntimeTests",
    dependencies: ["SwiftUIRuntime"]
  )
)
products.append(.executable(name: "Counter", targets: ["Counter"]))
let package = Package(
  name: "SwiftUIPort",
  platforms: [.macOS(.v11)],
  products: products,
  dependencies: packageDependencies,
  targets: targets,
  cxxLanguageStandard: .cxx17
)
