// The user-facing module. On Windows and Linux there is no system SwiftUI, so
// this module can use the name and `import SwiftUI` keeps working.
//
// It is deliberately not built on macOS: a package module may not shadow the
// system SwiftUI framework, and the macOS build only exercises SwiftUIRuntime.
//
// Unofficial; not affiliated with Apple.

@_exported import SwiftUIRuntime
@_exported import SwiftUIPort
