# SwiftUIPort

**Unofficial; not affiliated with Apple.**

SwiftUI's declarative API shape, translated onto [nativeapi](https://github.com/libnativeapi/nativeapi)'s
native Windows and Linux controls. This is an independent implementation, not a
port of Apple's SwiftUI source, and it does not try to reproduce SwiftUI's
renderer.

```swift
import SwiftUI

@main
struct CounterApp: App {
  var body: some Scene {
    WindowGroup("Counter") {
      CounterView()
    }
  }
}

struct CounterView: View {
  @State private var count = 0

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Text("Count: \(count)")
      HStack(spacing: 8) {
        Button("Increment") {
          count += 1
        }
        Button("Reset") {
          count = 0
        }
      }
      Spacer()
    }
    .padding(24)
  }
}
```

That program is checked in as [`Examples/Counter`](Examples/Counter/CounterApp.swift).
On Windows and Linux it is the CI smoke target; on macOS the same source compiles
against Apple's SwiftUI.

## What this is

The engine keeps SwiftUI's authoring model: value views, builders, state,
bindings, scoped environment, modifiers and WindowGroup. Windows adds generic
text/shape/layer drawing on a nativeapi window, including custom ButtonStyle
labels. Buttons retain native handles, activation, focus and accessible names.
Linux retains the native label/button/stack backend.

This is a **partial compatibility layer**. It contains no host application's
components, themes or tokens. It is not Apple's source or renderer, and does
not promise pixel equality. Custom drawing currently requires Windows;
the Windows backend supplies scrolling, vector images, native text editing,
popovers, gestures and basic animation. It remains smaller than Apple SwiftUI.
Read [docs/COMPAT.md](docs/COMPAT.md) and
[docs/DIVERGENCES.md](docs/DIVERGENCES.md) before adopting an API.

The port targets Windows and Linux. macOS applications and the Counter
reference example use Apple's SwiftUI; runtime tests also build on macOS.

## Requirements

- Swift 6.0 toolchain, language mode 5 (`swift-tools-version:5.9`). The
  current Windows runners ship Visual Studio 2026 / MSVC 14.51, whose STL
  requires Clang 20 or newer; the Windows CI therefore installs Swift 6.3.
  The package itself remains in language mode 5.
- A [nativeapi](https://github.com/libnativeapi/nativeapi) checkout with the
  Swift binding's platform support. The package consumes it as a **sibling path
  dependency** at `../nativeapi/bindings/swift`, or the path in
  `NATIVEAPI_SWIFT_PATH`:

  ```text
  Projects/
  ├── nativeapi/
  └── swiftui-port/
  ```

  The Windows backend requires the view batching and update scheduling APIs
  in [libnativeapi/nativeapi#34](https://github.com/libnativeapi/nativeapi/pull/34).
  Use the nativeapi revision pinned in `.github/workflows/ci.yml` or a revision
  that includes those APIs. macOS builds `SwiftUIRuntime` for its tests and the
  Counter example against Apple's SwiftUI without a nativeapi dependency.
- Linux: `pkg-config`, `libgtk-3-dev`, `libx11-dev`, `libxi-dev` (the binding
  gets its flags from pkg-config; no `unsafeFlags`).
- Windows: the official Swift toolchain with the Visual Studio build tools the
  Swift installer requires.

## Build and test

macOS builds the platform-independent engine for its test suite, and builds the
Counter example against **Apple's SwiftUI** (the port's own `SwiftUI` facade is
not built there). The test suite needs no window; `swift run Counter` opens a
normal SwiftUI window:

```bash
swift build
swift test
swift run Counter
```

Linux and Windows build the engine, the nativeapi backend and the example:

```bash
swift build
swift test
swift run Counter
```

For the verified Windows source-build path (Swift 6.4.2, MSVC and Windows SDK),
prepare nativeapi's source symlink and use the SwiftPM native builder:

```powershell
$env:NATIVEAPI_SWIFT_PATH = 'C:/src/nativeapi/bindings/swift'
& "$env:NATIVEAPI_SWIFT_PATH/scripts/prepare-windows.ps1"
swift build --build-system native
swift test --build-system native
swift run --build-system native Counter --smoke
```

Enable Windows Developer Mode if Git checked the core symlink out as a text
file. Initialize nativeapi's `core` submodule first. Swift 6.4 warns that the
native builder is deprecated; the commands above record the tested builder.

On Windows and Linux, `swift run Counter --smoke` opens the window and asks the
port's runner to quit a few seconds later; CI uses it to prove the window, event
loop and renderer start. The window can also be closed normally. macOS runs the
example under Apple's SwiftUI, where the flag has no special meaning.

## Repository layout

```
Sources/SwiftUIRuntime/   view protocol, element tree, layout, diff, state
Sources/SwiftUIPort/      WindowsDrawingBackend, NativeViewBackend, app runner
Sources/CSwiftUIWindows/  generic GDI+ display list and native button bridge
Sources/SwiftUI/          facade: `import SwiftUI`
Examples/Counter/         the README program
Tests/SwiftUIRuntimeTests FakeBackend assertions for layout, diff and state
docs/                     architecture, compatibility, divergences
```

`SwiftUI` and `SwiftUIPort` are declared only off macOS. A package module cannot
shadow Apple's SwiftUI, so the port's facade is absent there. The `Counter`
example is declared on every platform: on macOS it compiles against Apple's
SwiftUI, and on Windows/Linux it compiles against the port's facade.

## Design in one paragraph

A render pass evaluates bodies under scoped environment/state, resolves
inherited properties, lays out the tree and diffs sibling identity. Backends
receive incremental commands and the complete tree after diffing. Windows
publishes a retained display list and updates native buttons using those
frames; Linux applies nativeapi layout properties. FakeBackend records commands
for platform-independent tests. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Compatibility

- API status: [docs/COMPAT.md](docs/COMPAT.md)
- Known behavioural and visual gaps: [docs/DIVERGENCES.md](docs/DIVERGENCES.md)
- Architecture and update strategy: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## License

MIT. See [LICENSE](LICENSE).
