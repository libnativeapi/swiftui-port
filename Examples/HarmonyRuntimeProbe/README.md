# HarmonyOS PC Swift runtime probe

This Stage-model HAP loads an ARM64 Node-API library from
`EntryAbility.onCreate`. The startup checks cover Swift standard library
collections and dynamic casts, Foundation JSON/URL/Date, a detached Swift task
with a task group, and a SwiftUIRuntime state update. The task returns its result
to the ArkTS thread through a Node-API thread-safe function.

An ArkUI `ContentSlot` hosts a native text node and button created from the
SwiftUIRuntime tree using its layout frames. Clicking the native button sends
its node ID back to the Swift renderer, which updates `@State` and supplies
the new label text.

The same HAP also has a Gallery mode that compiles the real DazzUI SwiftUI
`AppView`, component stories and theme panel. The Swift renderer resolves
state and layout. A JSON bridge publishes the tree to ArkUI, which displays
native text, buttons, editors, scroll containers, SVG icons and paths.

## Build and run

Use a Mac with DevEco Studio (API 26 SDK), the Swift.org Swift 6.4.2 release
toolchain, and a running ARM64 HarmonyOS PC (2in1) emulator.

```sh
./run-emulator.sh
python3 verify-controls.py
python3 verify-gallery.py
```

The script defaults to `127.0.0.1:5555`. Set `HARMONY_DEVICE` to select a
different HDC target or `DEVECO_STUDIO_HOME` to point to DevEco's `Contents`
directory. The unsigned debug HAP is intended for the emulator.

`prepare-runtime.sh` downloads and checks the matching Swift.org Static Linux
SDK. Set `SWIFT_STATIC_SDK_ARCHIVE` to reuse the archive, or
`SWIFT_TOOLCHAIN_BIN` to point to the release toolchain's `usr/bin`. For a
separate build host, run the preparation script, copy the generated
`.build/runtime/` directory to the same project location there, then run
`SWIFT_RUNTIME_PREPARED=1 ./run-emulator.sh` on the DevEco host.

Success is reported in the UI and in the current process's HiLog output.
The second command exercises the native button through the emulator's input
tool and checks that the Swift label changes from `Count: 1` to `Count: 2`.
The third command starts Gallery mode and exercises it through the same input
tool. The equivalent manual launch is:

```sh
hdc shell aa force-stop dev.swiftuiport.runtimeprobe
hdc shell aa start -b dev.swiftuiport.runtimeprobe -a EntryAbility --ps gallery true
```

Set `HARMONY_GALLERY_SCREENSHOTS` to a directory when running
`verify-gallery.py` to save emulator screenshots of Button in both
appearances, Calendar, Overview, and the open Collapsible example.

The preparation script also needs a DazzUI checkout that includes
[the SwiftUI HarmonyOS packaging changes](https://github.com/dazzlabs/dazzui/pull/13).
It defaults to a checkout in
`dazzlabs/dazzui` alongside the `libnativeapi` directory. Set
`DAZZUI_SWIFT_PATH` to override the path to `packages/swift/DazzUI`.
For a separate build host, also copy
`entry/src/main/resources/rawfile/fluent/` alongside the generated runtime
objects before assembling the HAP.

```text
SWIFT_RUNTIME_PROBE PASS values=217,225
SWIFT_FOUNDATION_PROBE PASS value=42
SWIFT_RENDERER_PROBE PASS value=1
SWIFT_CONCURRENCY_PROBE PASS value=42
SWIFT_ARKUI_PROBE PASS Count: 1 -> Count: 2
```

## Linking

The Static Linux SDK provides the Swift standard library archives and the
`swiftrt.o` startup object that registers Swift metadata when the library
loads. DevEco's NDK links them into `libswiftprobe.so` against HarmonyOS libc.
The HAP also includes the NDK's `libc++_shared.so`. The preparation script
removes the Linux libc++abi exception-storage member from its private archive
copy so the shared library uses the NDK's exception TLS implementation.
Two Linux-only Foundation symbols are resolved locally in the probe. The
program-name variable uses the fixture's bundle name and the subprocess
working-directory action reports `ENOTSUP`.
The Gallery connects Swift's main dispatch queue to the ArkTS environment's
libuv loop for work enqueued to `MainActor`.

Verified on `NativeAPI_Desktop` (ARM64, HarmonyOS 7.0.0.107, API 26). The
Gallery backend is still a prototype. Updates publish a full tree, and ArkUI
retains controls by Swift node ID when their parent is unchanged. The
layout uses HarmonyOS Native Drawing to measure fonts. Frames use ArkUI
viewport units, while path and clip commands are converted to physical
pixels. The emulator check covers Button typography, Button → Calendar →
Overview, selecting Bright and Studio, light → dark → light, opening and
closing Collapsible, sidebar scrolling, and filtering through the native
search field. Context menus, clipboard copying, visual parity across the
full gallery, and physical devices still need integration and validation.
