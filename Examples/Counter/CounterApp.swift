import SwiftUI
#if os(macOS)
import AppKit

/// A SwiftPM executable is not an app bundle, so AppKit starts it as a
/// background app: the window exists but opens behind the terminal. Make it a
/// regular foreground app and activate it once launched.
final class CounterAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
#endif

@main
struct CounterApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(CounterAppDelegate.self) private var appDelegate
  #endif

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
