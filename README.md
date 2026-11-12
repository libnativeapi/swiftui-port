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

That program is checked in as [`Examples/Counter`](Examples/Counter/CounterApp.swift)
and is the CI smoke target: `swift run Counter`.

## What this is

The engine keeps SwiftUI's authoring model — a `View` protocol with `body`,
`@ViewBuilder`, `@State`/`@Binding`, stacks, modifiers and `WindowGroup` — and
turns it into native control creation, insertion, removal, property updates and
reordering. There is no custom drawing layer and no widget reimplementation:
`Text` is a native label, `Button` is a native button, and stacks are native
containers.

The important consequence is stated up front: **the visual result is not
identical to Apple SwiftUI.** nativeapi provides native desktop controls and a
row/column layout engine; it has no drawing API, no animation system, no
variable fonts and no rich text. See [docs/DIVERGENCES.md](docs/DIVERGENCES.md)
before judging a screenshot against SwiftUI.

## What this is not

- Not a reimplementation of SwiftUI's renderer, layout system or animation.
- Not a source-level port: no Apple SwiftUI code is used or copied.
- Not a macOS target. macOS already has SwiftUI; this project targets Windows
  and Linux.
- Not an embedded web view or a Flutter-like render engine. Real platform
  controls are used.
- Not a complete SwiftUI. The v0.1 symbol set is in
  [docs/COMPAT.md](docs/COMPAT.md); everything else is explicitly missing.

## Requirements

- Swift 6.0 toolchain, language mode 5 (`swift-tools-version:5.9`).
- A [nativeapi](https://github.com/libnativeapi/nativeapi) checkout with the
  Swift binding's platform support. The package consumes it as a **sibling path
  dependency** at `../nativeapi/bindings/swift`:

  ```text
  Projects/
  ├── nativeapi/
  └── swiftui-port/
  ```

  The platform support is currently proposed in
  [libnativeapi/nativeapi#33](https://github.com/libnativeapi/nativeapi/pull/33).
  Until that lands, check out the `swift-desktop-platforms` branch there.
  macOS only builds `SwiftUIRuntime` and does not need nativeapi.
- Linux: `pkg-config`, `libgtk-3-dev`, `libx11-dev`, `libxi-dev` (the binding
  gets its flags from pkg-config; no `unsafeFlags`).
- Windows: the official Swift toolchain with the Visual Studio build tools the
  Swift installer requires.

## Build and test

macOS builds only the platform-independent engine, so the whole test suite can
run without opening a window:

```bash
swift build
swift test
```

Linux and Windows build the engine, the nativeapi backend and the example:

```bash
swift build
swift test
swift run Counter
```

`swift run Counter --smoke` opens the window and asks the application to quit a
few seconds later; CI uses it to prove the window, event loop and renderer
start. The window can also be closed normally.

## Repository layout

```
Sources/SwiftUIRuntime/   view protocol, element tree, layout, diff, state
Sources/SwiftUIPort/      NativeViewBackend + App/WindowGroup runner
Sources/SwiftUI/          facade: `import SwiftUI`
Examples/Counter/         the README program
Tests/SwiftUIRuntimeTests FakeBackend assertions for layout, diff and state
docs/                     architecture, compatibility, divergences
```

`SwiftUI` and `SwiftUIPort` are declared only off macOS. A package module cannot
shadow Apple's SwiftUI, so the macOS build stops at `SwiftUIRuntime` and its
tests.

## Design in one paragraph

A render pass evaluates `body` into an `Element` tree, resolves inherited
foreground/disabled values, assigns diff keys (explicit `.id` or structural
position), and runs a reference layout. The diff compares that tree with the
mounted one and emits only the commands needed: `create`, `insert`, `remove`,
`move`, `setProps`, `setFrame`. `NativeViewBackend` applies those commands to
nativeapi views; `FakeBackend` records them so the engine is testable on macOS.
Details and the nativeapi mapping table are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Compatibility

- API status: [docs/COMPAT.md](docs/COMPAT.md)
- Known behavioural and visual gaps: [docs/DIVERGENCES.md](docs/DIVERGENCES.md)
- Architecture and update strategy: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## License

MIT. See [LICENSE](LICENSE).
