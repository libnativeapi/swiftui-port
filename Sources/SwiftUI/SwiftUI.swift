// The user-facing module for Windows, Linux and WebAssembly.
//
// Unofficial; not affiliated with Apple.

@_exported import SwiftUIRuntime
#if os(WASI)
  @_exported import SwiftUIWeb
#else
  @_exported import SwiftUIPort
#endif
