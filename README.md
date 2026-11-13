# SwiftUIPort

**Unofficial; not affiliated with Apple.**

SwiftUI's declarative API shape for Windows, Linux and the browser. Desktop builds use
[nativeapi](https://github.com/libnativeapi/nativeapi), and Web builds use WebAssembly and
browser controls. This is an independent implementation, not a
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
The same source builds for Windows, Linux and WebAssembly. Desktop macOS
builds compile it against Apple's SwiftUI.

## What this is

The engine keeps SwiftUI's authoring model: value views, builders, state,
bindings, scoped environment, modifiers and WindowGroup. The Windows and
Linux backends draw text, shapes and layers in a nativeapi window, including
custom ButtonStyle labels. Native controls supply activation, focus,
accessible names and text editing.

This is a **partial compatibility layer**. It contains no host application's
components, themes or tokens. It is not Apple's source or renderer, and does
not promise pixel equality. Both drawing backends supply scrolling, vector
images, native text editing, popovers, gestures and basic animation.
Read [docs/COMPAT.md](docs/COMPAT.md) and
[docs/DIVERGENCES.md](docs/DIVERGENCES.md) before adopting an API.

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

## Build for the web

Use the Swift.org Swift 6.4.2 toolchain and matching
[Swift SDK for WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html)
on macOS or Linux, with Node.js and npm for packaging. With the toolchain selected,
run these commands from the repository root.

```bash
swift sdk install https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
./scripts/build-web.sh
python3 -m http.server 8000 --directory .build/web
```

With Swiftly on macOS, `swiftly run ./scripts/build-web.sh +6.4.2` selects the
Swift.org toolchain for this build. Open [localhost:8000](http://localhost:8000)
to try Counter. Serve `.build/web` from a static HTTP host. The directory
includes the WebAssembly module and its JavaScript dependencies.

The script selects the Web package graph with `SWIFTUI_PORT_WEB=1`, uses a
separate SwiftPM scratch directory and packages the executable with
JavaScriptKit. It accepts an executable product name and a build configuration
as optional arguments, for example `./scripts/build-web.sh Counter debug`.
Web builds require no nativeapi checkout.

Web apps use the same `import SwiftUI`, `@main` and `WindowGroup` entry point.
The browser lays out the app to the size of `#swiftui-root` and uses native
HTML controls for buttons, text fields and scrolling. See
[docs/DIVERGENCES.md](docs/DIVERGENCES.md) for Web-specific limits.

For a separate Swift package, add the `SwiftUI` product from this package and
JavaScriptKit's `PackageToJS` command plugin dependency. Set
`SWIFTUI_PORT_WEB=1` when invoking `swift package --swift-sdk <id> js` for your
executable. Use [Web/index.html](Web/index.html) as a host page. For deeply
nested views in debug builds, use the WASI stack size linker setting on
Counter's executable target in [Package.swift](Package.swift).

## Repository layout

```
Sources/SwiftUIRuntime/   view protocol, element tree, layout, diff, state
Sources/SwiftUIPort/      Windows and Linux drawing backends, app runner
Sources/SwiftUIWeb/       DOM renderer and WebAssembly app runner
Sources/CSwiftUIWindows/  generic GDI+ display list and native button bridge
Sources/SwiftUI/          facade: `import SwiftUI`
Examples/Counter/         the README program
Web/                      browser entry page
Tests/SwiftUIRuntimeTests FakeBackend assertions for layout, diff and state
docs/                     architecture, compatibility, divergences
```

## Design in one paragraph

A render pass evaluates bodies under scoped environment/state, resolves
inherited properties, lays out the tree and diffs sibling identity. Backends
receive incremental commands and the complete tree after diffing. Windows
publishes a retained GDI+ display list. Linux paints the tree with Cairo and
Pango in GTK. The Web backend retains DOM elements by node identity and
positions them using the shared layout frames.
FakeBackend records commands for platform-independent tests. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Compatibility

- API status: [docs/COMPAT.md](docs/COMPAT.md)
- Known behavioural and visual gaps: [docs/DIVERGENCES.md](docs/DIVERGENCES.md)
- Architecture and update strategy: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## License

MIT. See [LICENSE](LICENSE).
