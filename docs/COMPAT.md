# Compatibility

**Unofficial; not affiliated with Apple.**

`supported` describes the API shape within this small subset; `partial` has
behavioral or platform limits. Neither means full SwiftUI conformance.
The table is checked against the source by `COMPATTests`.
See [DIVERGENCES.md](DIVERGENCES.md) for rendering and state semantics.

Windows and Linux use the shared runtime with platform drawing and native
controls. macOS applications use Apple's SwiftUI, while the port's runtime
tests can run on macOS.

| symbol | status | behavior |
|---|---|---|
| `View` | supported | value views with a `Body` |
| `View.body` | supported | recursively evaluated to primitives |
| `@ViewBuilder` | supported | 0–10 expressions, conditions, switches, loops |
| `EmptyView` | supported | no content |
| `AnyView` | supported | type erasure |
| `Group` | supported | transparent grouping |
| `ViewModifier` | partial | scoped environment and stored state; smaller than SwiftUI's DynamicProperty system |
| `VStack(alignment:spacing:)` | supported | vertical stack |
| `HStack(alignment:spacing:)` | supported | horizontal stack |
| `Spacer` | partial | leftover main-axis space; minLength is not enforced |
| `Text` | partial | native measurement, wrapping, ellipsis and concatenated styled runs |
| `Button(_:action:)` | supported | native button handle and activation |
| `Button(action:label:)` | partial | custom labels through ButtonStyle; unstyled labels flatten to a native text title |
| `ButtonStyle` | partial | custom visuals, native activation, isPressed; direct button modifier only |
| `Color` | partial | RGB/opacity, solid view, fixed colors; no dynamic/system color catalog |
| `Font` | partial | native family and size; Windows uses regular/bold weight buckets |
| `Rectangle` | partial | fill/strokeBorder |
| `RoundedRectangle` | partial | circular corners; continuous currently uses the same geometry |
| `Shape` | partial | custom Path, circles and rounded rectangles; trim is implemented for circular paths |
| `Edge` | supported | individual edges and Edge.Set for padding |
| `Alignment` | partial | frame and layer alignment |
| `@State` | partial | mounted structural path, concrete view type and property position; single renderer |
| `@Binding` | supported | get/set pair and constant bindings |
| `@Environment` | partial | scoped snapshots retained by callbacks; no system-setting subscription |
| `EnvironmentKey` | supported | custom keys with default values |
| `EnvironmentValues` | partial | custom values, font, colorScheme and accessibilityReduceMotion |
| `@FocusState` | partial | Bool and optional-value bindings; native button/edit focus |
| `.padding(_:)` | supported | uniform, EdgeInsets and Edge.Set overloads |
| `.frame(width:height:alignment:)` | partial | ordered wrapper; alignment, min/max and infinity |
| `.background(_:)` | partial | solid colors and view builder layers |
| `.overlay` | partial | view layers, aligned without affecting base size |
| `.foregroundColor(_:)` | partial | inherited Text color; native unstyled button keeps platform colors |
| `.foregroundStyle` | partial | Color overload only |
| `.font` | partial | Text and styled button labels |
| `.lineLimit` | partial | wrapping and head/tail ellipsis; limited rich-text wrapping |
| `.lineSpacing` | partial | spacing between explicit lines |
| `.opacity` | partial | per-primitive alpha on Windows; Cairo groups on Linux |
| `.clipShape` | partial | vector drawing clip and rectangular native control viewport clipping |
| `.contentShape` | partial | rounded native button hit region on Windows; limited gesture hit testing |
| `.shadow` | partial | layered approximation |
| `.animation` | partial | opacity, rotation, scale and offset interpolation, repeat/delay; no general layout/color interpolation |
| `.hidden()` | partial | collapses layout instead of retaining space |
| `.disabled(_:)` | partial | inherited by descendants; inner false can re-enable |
| `.onTapGesture(perform:)` | partial | button actions and hit-tested host content |
| `.onHover` | partial | control/host hover and ancestor delivery |
| `.focused` | partial | Bool and optional-value bindings; no focus scopes |
| `.help` | partial | native button tooltips |
| `.id(_:)` | partial | diff identity and explicit state scope |
| `App` | supported | entry point supplied by SwiftUIPort |
| `Scene` | partial | one WindowGroup |
| `WindowGroup` | partial | one window, defaultSize and resize events |
| `@main` | supported | App.main() runner |
| `SwiftUI` module | supported | facade on Windows and Linux only |

## Additional drawing backend capabilities

| symbol | status | behavior |
|---|---|---|
| `ZStack` | supported | ordered layers with alignment and zIndex |
| `ForEach` | partial | stable data-ID state scopes; eager evaluation |
| `ScrollView` | partial | vertical/horizontal wheel input, viewport clipping and draggable vertical indicator |
| `LazyVStack` | partial | VStack layout; no virtualization |
| `LazyHStack` | partial | HStack layout; no virtualization |
| `Grid` | partial | shared columns across GridRow children |
| `LazyVGrid` | partial | flexible/adaptive columns; eager evaluation |
| `GeometryReader` | partial | proposal-driven children, local/global/named frames |
| `Layout` | partial | sizeThatFits/placeSubviews and type erasure; caches recreated per calculation |
| `Path` | partial | move, line, cubic curves, arcs and closures |
| `Canvas` | partial | vector fills, clipping, translation and scaling |
| `LinearGradient` | partial | evenly spaced color stops |
| `Image` | partial | bundled SVG path template images and raster files; no asset catalogs or symbol catalog |
| `TextField` | partial | native editor with binding, selection and IME; vertical axis uses multiline editing |
| `SecureField` | partial | native password editor |
| `ObservableObject` | partial | process-wide invalidation, one active renderer |
| `StateObject` | partial | lazy retained object, scoped by mounted identity |
| `ObservedObject` | partial | object and writable-key-path bindings |
| `EnvironmentObject` | partial | scoped object lookup |
| `.onAppear` | partial | post-mount lifecycle callback |
| `.onDisappear` | partial | removed view callback |
| `.onChange` | partial | Equatable value comparison after rendering |
| `.task` | partial | cancellable main-actor task, restarted by id |
| `.gesture` | partial | DragGesture; no simultaneous/priority gesture arbitration |
| `.onKeyPress` | partial | native key routing and ancestor handlers; limited character/layout mapping |
| `.keyboardShortcut` | partial | scoped key actions; Command shortcuts also accept Control |
| `.popover` | partial | root-layer presentation, edge flipping, outside/Escape dismissal and optional background interaction |
| `.presentationBackgroundInteraction` | partial | enabled/disabled background controls; outside host press dismisses first |
| `.contextMenu` | partial | right-click root-layer content, dismissed on selection |
| `withAnimation` | partial | marks synchronous state updates for supported interpolation |
| `.transition` | partial | accepted metadata; insertion/removal transitions not animated |
| `.accessibilityLabel` | partial | native control names; decorative nodes keep metadata without a full platform accessibility provider |
| `.border` | supported | shape overlay |
| `.cornerRadius` | partial | circular clipping geometry |

## Not implemented

| symbol | status | note |
|---|---|---|
| `List`, `NavigationStack`, `TabView` | missing | compose containers where appropriate |
| `Toggle`, `Slider`, `Picker` | missing | host libraries may compose these from generic primitives |
| `Menu`, sheets, alerts | missing | popover/contextMenu are available; no complete SwiftUI presentation family |
| `.blur`, long-press gestures | missing | no blur filters or long-press recognizer |
| `Window`, `Settings`, `MenuBarExtra`, previews | missing | one-window runtime |
