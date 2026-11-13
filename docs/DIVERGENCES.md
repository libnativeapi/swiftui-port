# Known divergences from Apple SwiftUI

**Unofficial; not affiliated with Apple.** See [COMPAT.md](COMPAT.md) for API status.

## Platforms and controls

Windows uses a retained GDI+ display list on a nativeapi content HWND. Styled
buttons retain native BUTTON activation, capture, focus, names and disabled
state, using owner drawing. TextField/SecureField use native EDIT controls for
selection, clipboard commands and IME. Native controls are clipped to scroll
viewports. Their backgrounds are opaque; use a native placeholder rather than
placing placeholder text behind an editor. EDIT opacity uses a layered child
window, allowing an invisible editor behind a custom drawn value.

Decorative content has no complete UI Automation provider. Accessibility
modifiers retain metadata; native control names and modal control exclusion are
implemented, but a full accessible hierarchy and focus scopes are not.

Linux uses Cairo and Pango in a GTK 3 drawing area. GTK entries and text views
provide native editing and keyboard focus. GTK buttons expose native activation
and AT-SPI names. Drawn content lacks a complete accessible hierarchy.
macOS apps import Apple's SwiftUI; only runtime tests use this implementation.

## Drawing and text

GDI+ measures and draws Windows fonts in logical points. System sans, serif and
monospaced faces map to Segoe UI, Georgia and Consolas. Weights use regular/bold
buckets. There is no variable-font, dynamic-type or Apple font fallback parity.
Wrapping, newlines, line spacing and limited ellipsis are supported. Concatenated
Text runs retain font/color but do not form a full attributed text layout engine.
Linux uses the system font families and Pango weight selection, tracking and
underline. Multiline alignment and attributed text layout remain limited.

SVG template images support path geometry, including elliptical arcs, from a
viewBox. SVG styling, text, filters, embedded images and asset catalogs are not
implemented. Gradients use evenly spaced stops. Canvas supports path fills,
clipping and scale/translation. Circular trim is supported. Arbitrary path trim
is incomplete. Linux supports dashed strokes.

Rounded corners use circular arcs for both styles. Shadows are finite layered
approximations. Windows applies alpha per primitive; Linux composites Cairo
groups. Arbitrary clip paths constrain drawing; native controls use rectangular
viewport clipping.

## Layout, state and events

Layout uses proposals, nested frames/padding/layers, stack flexibility, grids,
scroll content extents and custom Layout callbacks. Lazy containers currently
evaluate all children. Layout priority, exact baseline alignment and full SwiftUI
proposal negotiation are absent. Spacer.minLength is not enforced. Very narrow
windows can overflow.

`.hidden()` collapses space and inner `.disabled(false)` can re-enable content.
Dragging and hovering are hit-tested in the host, and controls bubble key/focus
callbacks to their ancestors. Gesture priority/composition and full keyboard
layout-to-character conversion are not implemented.

State is scoped by structural path, concrete type and property position; `.id`
and ForEach data IDs add stable scopes. StateObject initializes lazily and retains
its object. Published writes invalidate after updating storage. Environment
snapshots survive callbacks. Reflection installs directly stored wrappers, not
SwiftUI's complete DynamicProperty machinery. The registry is process-wide and
supports **one active renderer**.
Local State reads are tracked for incremental body evaluation. ObservableObject
notifications still invalidate globally; lazy containers are not virtualized.
Measurement and placement caches reuse unchanged geometry. GeometryReader can
retain size-only content during translation; position readers and opaque custom
layout/guide closures stay conservative. The Windows backend verifies display
commands before reusing integer-pixel scroll interiors, and otherwise repaints.
Native button HWNDs inside scroll content can remain visible in the Win32 style
while clipped offscreen; viewport geometry and Tab eligibility determine whether
they can receive input. Debug builds retain
Swift's unoptimized overhead; use release builds for interactive performance.

Popovers are hoisted above clipping, flip at available edges and dismiss on
outside press or Escape. PresentationBackgroundInteraction can keep underlying
controls enabled for inline editing; outside host presses still dismiss first.
Native separate windows and custom attachment rectangles/alignment are not
complete. Context menus are drawn content, not native OS menus.

## Lifecycle and motion

Appearance/change/disappearance callbacks run after mounting. Tasks cancel when
their view disappears or task id changes. The Windows bridge pumps Swift's main
Dispatch queue alongside NativeAPI's Win32 loop. Linux watches libdispatch's
main queue descriptor from the GTK loop. Both use the Swift runtime's
`_dispatch_main_queue_callback_4CF` export.

Both backends interpolate rotation, scale, opacity and offset, including repeat and
delay. Timing curves currently interpolate linearly. Layout/color interpolation,
entry/exit transitions and exact presentation-time hit geometry are incomplete.
Reduced motion can be supplied through EnvironmentValues.

WindowGroup supplies one native window and defaultSize. There is no multi-window
scene management or state restoration. Windows executables reserve 16 MiB
of stack for deeply nested declarative trees. Headless and native integration
tests demonstrate behavior, not pixel equivalence with Apple SwiftUI.
