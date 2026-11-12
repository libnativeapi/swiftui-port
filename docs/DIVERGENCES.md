# Known divergences from Apple SwiftUI

**Unofficial; not affiliated with Apple.**

SwiftUIPort reproduces SwiftUI's authoring shape, not its renderer. This file
lists the differences that are visible to a user or that can change behaviour.
If a difference is not here, it is either covered by
[COMPAT.md](COMPAT.md) as missing or it is a bug.

## Visual differences

### Native controls, not SwiftUI's drawing

Every element wraps a real platform control: `Label` / `Button` / `GtkButton` /
`NSButton`, inside a nativeapi `View` container. nativeapi has no canvas, no
custom drawing, no gradients and no compositing API. The result therefore has
the host toolkit's metrics, focus ring, button chrome, font and DPI behaviour.

A window produced by this project will never be pixel-identical to the same
SwiftUI code on Apple platforms. That is expected, not a regression.

### Text is single-line and measured with fake metrics

The engine's reference layout treats every character as 8 pt wide and every
line as 20 pt tall. The native backend lets the platform label measure real
text. There is no line wrapping, truncation policy, dynamic type or variable
font support. Newlines are passed to the native control rather than laid out by
the engine.

### No fonts, corners, shadows or effects

`.font`, `.cornerRadius`, `.shadow`, `.opacity`, `.border` and `.clipShape` do
not exist in v0.1. `frame` maps to nativeapi's preferred size, and
`background` maps to a solid native background color.

### Stack layout only

`VStack` and `HStack` are native row/column containers. There is no `ZStack`,
`ScrollView`, `List` or `GeometryReader`. Padding is implemented as an extra
native container with padding; the extra container can affect focus traversal
and native background painting.

### Background and padding ordering

Because `.padding` is an explicit wrapper element, these two chains differ, as
they do in SwiftUI:

```swift
Text("A").padding(8).background(.red)   // red covers the padding
Text("A").background(.red).padding(8)   // red covers only the text
```

Other modifiers collapse onto one element, so their relative order generally
does not matter.

### `.frame` alignment is not applied

`.frame(width:height:alignment:)` accepts an alignment for source compatibility
but does not reposition content inside the frame. A leaf is given a preferred
size and the platform control's own alignment applies; a container is given a
preferred size and its stack layout applies.

## Behavioural differences

### `.hidden()` changes layout

nativeapi's `setVisible(false)` also excludes a view from its parent's stack
layout. SwiftUI's `.hidden()` keeps the view's space reserved. In SwiftUIPort a
hidden child collapses and following siblings move up.

### `.disabled()` may not cascade through native containers

The engine propagates `disabled` to every descendant and calls `setEnabled` on
each control. A native container's disabled state alone is not guaranteed to
disable its children on every toolkit; the engine's propagation is what makes
the common case work.

### `.onTapGesture` is button-only

nativeapi exposes `ButtonClickedEvent` but no general click event on a `View`.
`.onTapGesture` applied to a `Button` replaces its action; applied to `Text`,
`VStack`, an image, or any other view it is inert. There is no gesture
recognizer system, no drag, long press, hover or scroll gesture.

### `foregroundColor` is Text-only

Only `Label` exposes a text color. Applying `.foregroundColor` to a `Button`
does not change its title color. A container's foreground value is inherited by
descendant `Text` views.

### Identity is local to a parent

`.id` preserves an element when it moves among siblings: the diff emits a
`move` and the native control survives. Moving the same id to a **different**
parent removes it from the old parent and creates a new control under the new
one. SwiftUI can preserve identity across more structural changes.

### Structural identity shifts

Without `.id`, a view's diff key includes its sibling index. Inserting a new
view at the front recreates all the following siblings (and therefore their
native controls). Use `.id` for stable items.

### State is tied to construction position

`@State` slots are keyed by the structural path of the body that constructed the
view and by the order of `@State` initialization, not by an explicit `.id`.
Reordering views with `.id` keeps their native views but may reset their state
if their construction position changes. Conditional branches at the same
position share a state slot.

State is not pruned when a subtree disappears, so a view that is removed and
re-added can find its old value. This is a small leak and a semantic difference
from SwiftUI, which usually resets state for a newly identified view.

There is no `@StateObject`, `ObservableObject`, `@ObservedObject`,
`@EnvironmentObject` or `@Environment`.

### Modifier evaluation is eager

`VStack { ... }` evaluates its content closure when the view value is
constructed, not lazily at layout time. That is fine for the v0.1 tree, but it
means `body` side effects and state registration happen earlier than a SwiftUI
user might expect. `@ViewBuilder` still supports conditionals and loops.

### One window, fixed initial size

`WindowGroup` creates one 480×320 window. There is no multi-window scene
management, restoration, `Window` scene, `MenuBarExtra`, or `Settings`. A
resize is observed and the reference layout/root frame are updated, but the
native layout does the actual child placement.

### `AnyView` erases kind

The diff sees an `AnyView` as the element it wraps, so type erasure is mostly
transparent. Wrapping a view in `AnyView` can still change structural identity
because it changes the value's type at that position; prefer concrete types and
generic containers.

### No animation

Even without `withAnimation`, SwiftUI animates some layout changes by default in
some contexts. SwiftUIPort never animates; a state change re-lays out and
redraws immediately. There is no implicit transition, no animation transaction
and no timing curve.

## Platform differences

The three desktop toolkits disagree about intrinsic sizes, button height,
default fonts, focus rings, high-DPI rounding and theme colors. The same
SwiftUIPort tree can therefore look different on Windows (Win32 common
controls), Linux (GTK 3) and macOS (not a supported target for the facade).
Screenshots in `docs/` are from one Linux host and one toolkit version, not a
cross-platform guarantee.

## Non-goals for v0.1

Animation, custom drawing, `Canvas`, `GeometryReader`, `ZStack`, `ScrollView`,
`List`, the gesture system, fonts, corner radius, shadows, rich text,
accessibility, IME, text fields, navigation, multiple windows and observation
are all out of scope. [COMPAT.md](COMPAT.md) is the authoritative missing list.
