// swift-tools-version:5.9

import Foundation
import PackageDescription

// SwiftUIPort — a declarative SwiftUI-shaped API over nativeapi's native views.
// Unofficial; not affiliated with Apple.
//
// The package has three layers:
//   SwiftUIRuntime  engine: view protocol, element tree, layout, diff, state.
//                   No nativeapi dependency, so it builds and tests on macOS.
//   SwiftUIPort     the nativeapi backend and app/window integration.
//   SwiftUI         the user-facing facade (`import SwiftUI`).
//
// SwiftUI and SwiftUIPort are only declared off macOS: macOS already ships a
// module named SwiftUI, and a package module may not shadow it. On macOS the
// build contains SwiftUIRuntime, its tests, and the Counter example compiled
// against Apple's SwiftUI, so `swift run Counter` opens a normal SwiftUI window.
//
// The nativeapi Swift package is consumed as a sibling checkout at
// ../nativeapi/bindings/swift (see README "Requirements"). It is intentionally
// a path dependency: this project is not published to a package registry.

#if os(macOS)
  let packageDependencies: [Package.Dependency] = []
#else
  let packageDependencies: [Package.Dependency] = [
    .package(
      name: "NativeAPI",
      path: ProcessInfo.processInfo.environment["NATIVEAPI_SWIFT_PATH"]
        ?? "../nativeapi/bindings/swift")
  ]
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
  targets.append(
    .target(
      name: "CSwiftUIWindows", dependencies: [.product(name: "CNativeAPI", package: "NativeAPI")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedLibrary("gdiplus"), .linkedLibrary("comctl32")]))
  let drawingDependencies: [Target.Dependency] = ["CSwiftUIWindows"]
  targets.append(
    .target(
      name: "CSwiftUIWindowsTestSupport", dependencies: ["CSwiftUIWindows"],
      path: "Tests/CSwiftUIWindowsTestSupport", publicHeadersPath: "include"))
  targets.append(
    .testTarget(
      name: "WindowsDrawingTests", dependencies: ["CSwiftUIWindowsTestSupport", "SwiftUIPort"]))
#else
  let drawingDependencies: [Target.Dependency] = []
#endif

#if !os(macOS)
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
#endif

#if os(macOS)
  let counterDependencies: [Target.Dependency] = []
#else
  let counterDependencies: [Target.Dependency] = ["SwiftUI"]
#endif

targets.append(
  .executableTarget(
    name: "Counter",
    dependencies: counterDependencies,
    path: "Examples/Counter"
  )
)
targets.append(
  .testTarget(
    name: "SwiftUIRuntimeTests",
    dependencies: ["SwiftUIRuntime"]
  )
)
var products: [Product] = [
  .library(name: "SwiftUIRuntime", targets: ["SwiftUIRuntime"])
]

#if !os(macOS)
  products += [
    .library(name: "SwiftUIPort", targets: ["SwiftUIPort"]),
    .library(name: "SwiftUI", targets: ["SwiftUI"]),
  ]
#endif

products.append(.executable(name: "Counter", targets: ["Counter"]))
let package = Package(
  name: "SwiftUIPort",
  platforms: [.macOS(.v11)],
  products: products,
  dependencies: packageDependencies,
  targets: targets,
  cxxLanguageStandard: .cxx17
)
