# Architecture

**Unofficial; not affiliated with Apple.**

This document describes what the engine does, where the platform boundary is,
and how a SwiftUI-shaped declaration becomes nativeapi view operations. The
short version: the runtime computes an element tree and a reference layout, the
diff emits a minimal command list, and a backend maps those commands onto real
platform controls.

## Module graph

```
                    +----------------------+
   user code ------>|        SwiftUI       |   facade, non-macOS only
                    | @_exported imports   |
                    +----------+-----------+
                               |
              +----------------+----------------+
              |                                 |
     +--------v---------+              +--------v---------+
     |   SwiftUIPort    |              |  SwiftUIRuntime  |
     | NativeViewBackend|              |  element tree    |
     | App / Window     |              |  layout / diff   |
     | runner           |              |  state / builder |
     +--------+---------+              +------------------+
              |
     +--------v---------+
     |     NativeAPI    |
     | nativeapi core   |
     +------------------+
```

- **SwiftUIRuntime** is platform independent and imports no native API. It can
  be built and tested on macOS without nativeapi.
- **SwiftUIPort** imports `NativeAPI`, owns the window and application loop, and
  implements the one real backend.
- **SwiftUI** is the facade. On Windows and Linux it exports both lower modules
  so `import SwiftUI` is sufficient. It is not built on macOS because a package
  module may not shadow the system SwiftUI framework.
- `SwiftUIPort` and `SwiftUI` are declared behind `#if !os(macOS)` in
  `Package.swift`; the dependency on the nativeapi Swift package is declared in
  the same condition.
- `Counter` is declared on every platform. On macOS it has no package
  dependency and imports Apple's SwiftUI, so `swift run Counter` demonstrates the
  same example with the system framework. On Windows and Linux it depends on the
  port's `SwiftUI` facade.

## A render pass

`Renderer` owns the mounted tree and does this for every pass:

1. **Evaluate.** `_render(root, path: [])` walks `View.body` until it reaches a
   primitive view. `@ViewBuilder` blocks become fragment elements; a container
   flattens those fragments into its child list.
2. **Normalize.** Fragments and `EmptyView`s are removed. A top-level fragment
   with several children becomes a zero-spacing vertical container.
3. **Resolve environment.** `.foregroundColor` and `.disabled` are inherited
   down the tree. Explicit values on a descendant win; `.disabled(false)`
   re-enables a subtree.
4. **Assign keys.** Each element gets a diff key: an explicit `.id` value, or
   `(parent key, child index, kind)` for structural identity.
5. **Lay out.** `LayoutEngine` measures with fixed fake text metrics and writes
   a reference frame into every element.
6. **Diff.** The new tree is compared with the mounted tree. Matched elements
   keep their `NodeID`; new elements get fresh IDs.
7. **Emit.** The backend receives one ordered command list.

The engine never re-creates a matched subtree just because an action closure
was rebuilt. Actions are kept in a `[NodeID: () -> Void]` table inside the
renderer and looked up by node ID when a native button fires.

## Backend protocol

```swift
public protocol RenderBackend: AnyObject {
  func perform(_ commands: [RenderCommand])
  var tapHandler: ((NodeID) -> Void)? { get set }
}
```

Commands:

| command | meaning |
|---|---|
| `create(id, kind, props)` | make a native control or container for this element |
| `insert(id, parent, index)` | attach it; `parent == nil` means the window content view |
| `remove(id)` | detach and dispose a whole subtree |
| `move(id, parent, index)` | reattach an existing view at a new sibling position |
| `setProps(id, props)` | update text/colors/visibility/layout properties in place |
| `setFrame(id, frame)` | the reference frame changed (only the root is applied by the native backend) |

A pass emits removals first, then creates/inserts/moves in new sibling order,
then property updates, then frame changes. A move is one command, not a
remove/create pair.

`FakeBackend` records commands and lets tests assert the exact sequence. It is
also what makes the engine testable on macOS without a native window.

## Identity and diffing

Two kinds of identity exist:

- **Explicit**: `.id(value)` makes the element's key that value. It is global
  within the tree, so reordering siblings by id emits a move.
- **Structural**: without an explicit id, the key is the parent's key plus the
  child's index and kind. Inserting at the front shifts every following key, so
  those siblings are recreated. This matches SwiftUI's structural identity
  intuition, and `.id` is the escape hatch.

The sibling diff:

1. Removes old keys that no longer exist (one command per subtree).
2. Walks the new children left to right. A matched key at the wrong position
   emits one `move`. A genuinely new key emits `create` + `insert` for its
   subtree. A matched key whose `kind` changed emits `remove` + `create`,
   because a `Text` cannot be mutated into a `Button` in place.
3. Emits `setProps` only when the effective props differ; `setFrame` only when
   the reference frame differs.

v0.1 does **not** move an element across different parents even if its explicit
id matches. Such an element is removed from the old parent and created under the
new one. See [DIVERGENCES.md](DIVERGENCES.md).

## Layout: reference and native

There are two layouts, on purpose:

- The **reference layout** in `SwiftUIRuntime` measures text with fixed metrics
  (8 pt per character, 20 pt line height by default), applies stack spacing,
  cross-axis alignment, padding and frame overrides. Tests assert these numbers,
  and the root frame comes from this pass.
- The **native layout** is nativeapi's row/column engine. It measures real
  platform controls, distributes `flex` to spacers, and positions children
  according to each child's alignment. This is what the user sees.

`NativeViewBackend` therefore maps the *declarative layout properties* (layout
axis, spacing, padding, flex, alignment, preferred size) rather than replaying
every reference frame. The root is the exception: the engine knows the window
content size, so the backend applies the root frame and updates it when the
window resizes. Applying reference frames to every child would fight the native
layout pass.

The two layouts agree on the v0.1 subset (top-to-bottom, left-to-right,
spacing, padding, spacers, preferred sizes) but not on text width or on native
control insets. That is expected.

## Nativeapi mapping

`Sources/SwiftUIPort/NativeViewBackend.swift` maps:

| Engine | nativeapi | Notes |
|---|---|---|
| `VStack` | `View` with `ViewLayout.Column` | spacing via `setSpacing`; each child gets `setAlignment` from the stack alignment |
| `HStack` | `View` with `ViewLayout.Row` | same, with top/center/bottom mapped to start/center/end |
| `.padding(...)` | plain `View` with `Column` layout, `setPadding` | an explicit wrapper, so background-before/after-padding keeps its order |
| `Text` | `Label` | `setText`, `setTextColor` |
| `Button` | `Button` | `setText`; click listener calls `tapHandler` |
| `Spacer` | `View` with `setFlex(1)` | takes leftover main-axis space |
| `.frame(width:height:)` | `setPreferredSize` | `0` means "intrinsic" in nativeapi |
| `.background(color)` | `setBackgroundColor` | |
| `.foregroundColor(color)` | `Label.setTextColor` | Text only; `Button` has no text-color API |
| `.hidden()` | `setVisible(false)` | nativeapi skips invisible children in layout |
| `.disabled(...)` | `setEnabled(false)` | resolved down the tree by the engine |
| root element | `Window.contentView.addSubview` + `setFrame` | updated on window resize |
| window resize | `Window` `resized` event | `Renderer.resize(to:)` |
| button click | `ButtonClickedEvent` | `Renderer.performTap(id)` |

All NativeAPI names in `SwiftUIPort` are fully qualified (`NativeAPI.View`,
`NativeAPI.Size`, `NativeAPI.Color`, ...) because `SwiftUIRuntime` also defines
`Color`, `Size`, `Point` and `EdgeInsets`.

## State

`@State` writes must survive the fact that `body` is re-evaluated and view
values are re-created. The runtime uses a process-wide `StateRegistry`:

- When a `@State` wrapper is initialized it registers a slot
  `(scope, ordinal)`.
- `scope` is the structural path of the body currently being evaluated.
- `ordinal` resets at the start of each body evaluation, so the same view value
  constructed in the same position finds the same slot.
- A write calls the renderer's `onChange`, which marks the tree dirty. The
  renderer finishes the current pass first, then re-renders (coalescing up to
  eight passes to avoid a loop).

`@Binding` is a get/set pair; it does not store anything. The parent passes
`$value`, the child mutates it, and the write goes through the same state slot
and invalidation path.

This is deliberately smaller than SwiftUI's property-wrapper system. State is
tied to construction position, not to an explicit `.id`; it is not pruned when
a subtree disappears; `@StateObject`, `@ObservedObject`, `@EnvironmentObject`
and `@Environment` are not implemented. See
[DIVERGENCES.md](DIVERGENCES.md).

## App and window lifecycle

`@main` resolves to `App.main()` in `SwiftUIPort`:

1. Evaluate `app.body` to a `Scene`, which must be a `WindowGroup`.
2. Create a native `Window`, set its title and an initial content size.
3. Construct the root view under the root `@State` scope.
4. Create `NativeViewBackend`, mount the renderer, show the window.
5. Listen for window resize, then call `Application.runWithWindow(window)`.
6. When the window closes, the platform loop returns and `main()` exits.

With `--smoke`, a background thread waits three seconds and calls
`Application.quit(0)`. nativeapi dispatches that to the UI thread, so the CI
smoke test exercises the real event loop rather than a special headless path.

## Testing

`Tests/SwiftUIRuntimeTests` has four groups:

- `LayoutTests`: fake metrics, stacks, spacers, padding, frames, inheritance.
- `DiffTests`: mount counts, prop-only updates, append/insert/remove, reorder
  by `.id`, kind replacement, and an unchanged tree producing no commands.
- `StateTests`: `@State` writes re-render and only update props; `@Binding`
  flows back to the parent; resize changes the root frame.
- `COMPATTests`: scans `docs/COMPAT.md` and the sources so the compatibility
  table cannot silently drift from the code.

The tests use `FakeBackend`, never a real window. macOS CI runs this suite and
builds `Counter` against Apple's SwiftUI (without launching the GUI); Linux and
Windows additionally build the port's backend and run the Counter smoke test.
