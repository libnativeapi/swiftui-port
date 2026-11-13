# Architecture

**Unofficial; not affiliated with Apple.**

## Modules and boundaries

- `SwiftUIRuntime`: platform-independent view values, builders, scoped
  environment, state, element tree, layout and diff. No native API imports.
- `SwiftUIPort`: nativeapi window/application lifecycle and platform backends.
- `CSwiftUIWindows`: generic Win32/GDI+ drawing, text measurement, edit and button
  painting, focus and tooltip bridge. Owns no application design tokens,
  components or theme recipes. Borrows the window/button HWNDs owned by nativeapi and owns EDIT children.
- `SwiftUI`: non-macOS facade exporting the two Swift modules.

macOS builds runtime tests and the Counter example against Apple's SwiftUI.
Windows/Linux use the facade. A host library owns its own components and
styles; the compatibility layer implements only generic SwiftUI concepts.

## Render pass

1. Begin state collection. Install stored wrappers by structural path, concrete
   view type and property position before evaluating each body.
2. Track state reads while evaluating bodies and modifiers under scoped
   EnvironmentValues. A local write invalidates its readers and ancestors;
   unaffected branches retain their element trees, state and lifecycle entries.
   ObservableObject and untracked geometry-state writes invalidate conservatively.
3. Normalize fragments, retain both slots of view layers, and resolve inherited foreground, disabled, visibility and alpha values.
4. Compute layout, evaluate geometry children, hoist presentations, prune state
   and assign sibling diff keys. Windows
   supplies a native text measurer; deterministic metrics serve engine tests.
5. Diff against the mounted tree, retaining NodeIDs for matched elements.
   Keys are local to sibling lists; an unchanged sibling order uses a linear
   path without key dictionaries or move-list scans.
6. Publish the updated tree and callbacks, send backend commands, then call
   `didRender(root)`. Rendering guards coalesce writes made during a pass;
   the Windows bridge batches deferred native notifications from a message turn.

Commands are create, insert, remove, move, setProps and setFrame. Removing a
node disposes its subtree. Actions are looked up by retained NodeID, so a
native callback never needs an old body closure. Reentrant writes are coalesced
into at most eight follow-up render passes.

## Windows backend

`WindowsDrawingBackend` sets nativeapi's content view to absolute layout and
publishes a retained display list after each diff. The bridge reparents borrowed
button HWNDs directly; NativeAPI retains their lifetime/events, while SwiftUI
owns layout without enrolling controls in a second layout tree. Shapes and Text share the
surface; padding/frame/layer nodes determine paint order and coordinates.
Native BUTTON HWNDs are created only for new button IDs and retained across
state, theme and resize changes. Removed controls unregister listeners and
subclasses before disposal. The renderer remains alive through the native
application loop.

`CSwiftUIWindows` subclasses the content HWND for buffered WM_PAINT. A retained
physical-pixel DIB is shared by the host and owner-drawn buttons. Display-list
comparison invalidates only changed ink bounds. Structural/clip/transform changes
repaint their common enclosing clip, or the full viewport when none is available.
Painting clips to the accumulated damage and reuses bounded font resources.
ScrollView controls share a fixed viewport and translated content HWND, including
nested scroll views. Scrolling moves the content host instead of every button;
viewport clipping and Tab eligibility keep offscreen controls out of input.
Translations use DeferWindowPos without intermediate redraws. The content host
copies the shared framebuffer once per damaged frame; independent EDITs and
unstyled buttons retain native painting. Styled buttons can also copy their
rectangle for native exposure/print messages. The native control still
handles mouse capture, Space activation, enabled state and BN_CLICKED. The
bridge adds Enter activation, ordered Tab navigation, hover/pressed/focus
callbacks, rounded hit regions and tooltips. EDIT notifications update bindings
after the native message unwinds, so a render can safely remove old controls.
Deferred focus events are checked against current HWND focus. Host events route
scrolling, gestures and shortcuts through the renderer. No global input is injected.

Only controls intersecting the viewport acquire native handles; existing handles
remain retained when scrolled away. Unchanged labels, frames, z-order and hit
regions skip native mutations. Local button regions exclude clipping already
performed by their viewport, so scrolling does not rebuild per-button HRGNs.
Offscreen text/images/shapes and transparent
layout boxes do not generate drawing commands. Lazy containers still construct
all children initially; local state can reuse their unchanged branches.
A focused container chooses one
native descendant, rather than requesting focus on every child.

`App.main` configures per-monitor V2 DPI awareness before application/window
initialization. Embedders should call `WindowsDrawingBackend.prepareApplication()`
before creating native windows, or provide their own DPI-aware application manifest.
All geometry is in logical points. Painting scales using GetDpiForWindow;
the drawing bridge converts borrowed button frames to the same device coordinates. Native text
measurement uses the same font choice as painting. Resize uses the window's
content size, not the event's decorated frame size. Framebuffer copies specify
both rectangles in pixels, avoiding GDI+'s implicit image-DPI scaling. Display
lists publish after native control updates, so intermediate messages still paint
the previous complete frame.

The backend's activate/nativeButton/advanceFocus methods allow integration
tests scoped to their own controls. Public core API and generated bindings
are unchanged by this drawing backend.

## Linux backend

`NativeViewBackend` consumes incremental commands and maps stacks/padding to
nativeapi row/column containers, Text to Label, and Button to Button. Native
layout determines child frames; only the root reference frame is applied.
Frames map to wrapper preferred sizes. Drawing-only nodes fail explicitly.
The full limitations of both backends are in [DIVERGENCES.md](DIVERGENCES.md).

## State, layout and testing

State uses a process-wide registry for one renderer. Bindings are get/set
closures; focus bindings wrap State. Environment values are saved/restored
around subtrees. `.id` and ForEach identifiers scope both diff identity and stored state.
Published values invalidate the active renderer; StateObject initialization is lazy.
Writes from one action or native notification batch are published together.
ScrollView retains its stored content when only its internal offset changes.
Lifecycle callbacks commit after mounting, and the Windows timer services tasks
and a limited set of animated drawing properties.

Stack measurement sums main-axis sizes and takes the largest cross-axis size.
Padding adds insets; frames constrain/alignment-place a child; layers measure
the base view only. Flexible frames/spacers consume remaining proposed space.
This is deliberately smaller than SwiftUI's layout system.
Measurements are cached by proposal and sizing inputs. Placement snapshots copy
geometry into the new tree without replacing callbacks or visual properties.
Unchanged evaluation revisions reuse mounted subtrees when inherited properties
also match. Moving them translates their frames; resizing reflows them. Their
diffs and key assignment are skipped only while geometry remains unchanged.
Changed text, fonts, constraints, alignment, scroll offsets and child identities
invalidate the relevant caches. Opaque custom layout/guide closures take the
conservative path. GeometryReader snapshots retain state and
lifecycle registrations when reused; size changes re-evaluate their content.
Readers of global/named positions re-evaluate when coordinates change, while
escaped proxies keep current coordinates after cached translation. Obsolete
layout cache entries are reclaimed every eight passes; changing the text
measurer or fallback metrics clears them immediately.

Integer-pixel scrolls can reuse the framebuffer's interior. The bridge verifies
that visible paint commands and their clip stacks are exact translations, that
the backdrop is uniform, and that no stationary overlay intersects the copy.
Exposed strips, edges and scroll indicators repaint. Content edits, fractional
pixel shifts, transforms, complex backgrounds and unpainted intermediate frames
fall back to normal drawing. Pixel regression tests compare reuse with fresh
rendering, including alpha, text, reverse scrolling and unsafe cases.

The runtime suite covers layout, diffing, state lifetime, environment scope,
custom modifiers, button styles and compatibility documentation. Native apps
can use the Windows backend to test real HWND activation and stable handles.
`Counter --smoke` opens a real window and exits after three seconds, exercising
the native application loop. Test metrics and actual font measurements are
distinct: headless assertions are not pixel conformance claims.
`Renderer.lastTimings` reports evaluation, environment, layout, finalization,
diff and backend publication in milliseconds; actual native painting is measured
separately by host integration benchmarks. Compare like build configurations.
`WindowsDrawingBackend.lastTimings` separates preparation, display-list recording,
control synchronization and publication. `lastPaintTimings` reports raster/copy
CPU time and paint count; `lastReusedPixels` reports successful scroll reuse.
