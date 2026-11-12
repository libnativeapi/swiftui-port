# Compatibility

**Unofficial; not affiliated with Apple.**

This is the authoritative v0.1 symbol list. `supported` means the symbol exists
and follows the documented SwiftUI shape for the v0.1 subset. `partial` means it
exists but has a documented limitation. `missing` means it is not implemented;
using it will not compile.

The status here and the `SwiftUIRuntimeTests` compatibility check are kept in
sync: a `supported`/`partial` row whose symbol is absent from `Sources/` fails
the test. Behavioural limits live in [DIVERGENCES.md](DIVERGENCES.md).

## Core view model

| symbol | status | note |
|---|---|---|
| `View` | supported | `associatedtype Body: View` and `var body: Body` |
| `View.body` | supported | evaluated until a primitive view is reached |
| `@ViewBuilder` | supported | 0–10 child expressions, `if`/`else`, `switch`, `for` |
| `EmptyView` | supported | renders nothing; dropped from containers |
| `AnyView` | supported | type-erased view; hides the concrete kind from the diff |
| `Never` | supported | the `Body` of primitives; not user-authored |

## Containers and content

| symbol | status | note |
|---|---|---|
| `VStack(alignment:spacing:)` | supported | top to bottom; default spacing 8 |
| `HStack(alignment:spacing:)` | supported | left to right; default spacing 8 |
| `Spacer` | partial | takes leftover main-axis space; `minLength` is stored but not enforced |
| `Text` | partial | single line; fixed fake metrics in the engine, native label at runtime |
| `Button(_:action:)` | supported | title-only button; action runs on the UI thread |
| `Color` | partial | RGB/opacity plus a few constants; no system/dynamic colors |
| `Edge` | supported | option set for `padding(_:_:)` |
| `HorizontalAlignment` | supported | leading/center/trailing for `VStack` |
| `VerticalAlignment` | supported | top/center/bottom for `HStack` |
| `Alignment` | partial | accepted by `frame`; alignment itself is not applied by the backend |

## State

| symbol | status | note |
|---|---|---|
| `@State` | partial | stable construction position; no `@StateObject` semantics |
| `@Binding` | supported | get/set pair, including `Binding.constant` |
| `Binding` | supported | the projected value of `@State` and `@Binding` |

## Modifiers

| symbol | status | note |
|---|---|---|
| `.padding(_:)` | supported | one value for all edges |
| `.padding(_:EdgeInsets)` | supported | per-edge insets |
| `.padding(_:Edge)` | supported | selected edges, e.g. `.padding(.horizontal, 8)` |
| `.frame(width:height:alignment:)` | partial | maps to `setPreferredSize`; `alignment` is accepted but not applied |
| `.background(_:)` | partial | `Color` backgrounds only (no view backgrounds) |
| `.foregroundColor(_:)` | partial | applies to `Text`; nativeapi's `Button` has no text-color API |
| `.hidden()` | partial | calls `setVisible(false)`; nativeapi also removes it from layout |
| `.disabled(_:)` | supported | inherited by descendants; `.disabled(false)` re-enables |
| `.onTapGesture(perform:)` | partial | effective on a `Button` (replaces its action); inert on other views |
| `.id(_:)` | partial | diff identity within one parent; no cross-parent moves |

## App and scenes

| symbol | status | note |
|---|---|---|
| `App` | supported | `@main` support is supplied by `SwiftUIPort` |
| `Scene` | partial | `WindowGroup` only |
| `WindowGroup` | supported | one window per app in v0.1 |
| `@main` | supported | resolves to `App.main()` from `SwiftUIPort` |
| `SwiftUI` module | supported | facade for non-macOS builds only |

## Missing

These are intentionally not implemented in v0.1. They are not compile errors or
silent fallbacks; the symbols simply do not exist.

| symbol | status | note |
|---|---|---|
| `withAnimation`, `.animation`, transitions | missing | no animation system in nativeapi |
| `Canvas` | missing | nativeapi has no drawing API |
| `GeometryReader` | missing | no geometry proposal/measurement protocol |
| `ZStack` | missing | nativeapi stacks are strictly row/column |
| `ScrollView` | missing | no native scroll container in the view API |
| `List`, `ForEach`, `LazyVStack` | missing | `for` loops in `@ViewBuilder` produce a flat fragment, not a list |
| gesture system (`gesture`, `DragGesture`, `LongPressGesture`) | missing | only a button click and `.onTapGesture` on a button |
| `.font`, font weight/design, dynamic type | missing | no font API on the Swift binding |
| `.cornerRadius` | missing | nativeapi views have no corner-radius API |
| `.shadow` | missing | nativeapi views have no shadow API |
| `.opacity`, `.blur`, `.border`, `.clipShape` | missing | no drawing/compositing API |
| rich text, `AttributedString`, `Text` concatenation, markdown | missing | controls take a plain string |
| accessibility modifiers and accessibility tree | missing | nativeapi has an accessibility manager but the Swift binding does not expose it for views |
| IME, marked text, text selection | missing | `TextField` itself is not implemented in v0.1 |
| `TextField`, `Toggle`, `Slider`, `Picker`, `Image` | missing | not in the v0.1 symbol set |
| `@StateObject`, `@ObservedObject`, `ObservableObject`, `@EnvironmentObject` | missing | no observation system |
| `@Environment`, `EnvironmentValues` as public API | missing | environment resolution is internal to the engine |
| `NavigationStack`, `TabView`, `Sheet`, `Alert`, `Menu` | missing | no scene/navigation presentation model |
| `.onAppear`, `.onDisappear`, `.task`, lifecycle modifiers | missing | no view lifecycle callbacks |
| multiple windows, `Window`, `MenuBarExtra`, `Settings` | missing | one `WindowGroup` and one window |
| `#Preview` and Xcode previews | missing | not an Xcode-integrated package |
| keyboard shortcuts and focus system | missing | not exposed in the v0.1 view API |
