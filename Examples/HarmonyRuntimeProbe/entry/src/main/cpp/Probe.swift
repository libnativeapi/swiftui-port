import Foundation
import SwiftUIRuntime

private final class Sample {
  let values: [Int32]

  init(seed: Int32) {
    values = [seed, seed &+ 1]
  }
}

@inline(never)
private func runtimeValue(_ value: Any) -> Int32 {
  guard let sample = value as? Sample else { return -1 }
  let values = Dictionary(uniqueKeysWithValues: zip(["first", "second"], sample.values))
  let text = String(decoding: [83, 119], as: UTF8.self)
  guard let first = values["first"], let second = values["second"] else { return -2 }
  return first &+ second &+ Int32(text.utf8.reduce(0) { Int($0) + Int($1) })
}

@_cdecl("swift_runtime_probe")
public func swiftRuntimeProbe(_ seed: Int32) -> Int32 {
  runtimeValue(Sample(seed: seed))
}
@_cdecl("swift_foundation_probe")
public func swiftFoundationProbe() -> Int32 {
  let payload = Data(#"{"value":42}"#.utf8)
  guard let decoded = try? JSONDecoder().decode([String: Int32].self, from: payload),
        let value = decoded["value"],
        URL(string: "https://example.org/probe")?.path == "/probe",
        Date(timeIntervalSince1970: 123).timeIntervalSince1970 == 123
  else { return -1 }
  return value
}

@_cdecl("swift_concurrency_probe")
public func swiftConcurrencyProbe(
  _ context: UnsafeMutableRawPointer?, _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
) {
  let handle = context.map { UInt(bitPattern: $0) } ?? 0
  Task.detached {
    let result = await withTaskGroup(of: Int32.self, returning: Int32.self) { group in
      for value: Int32 in [13, 29] {
        group.addTask {
          await Task.yield()
          return value
        }
      }
      return await group.reduce(0, +)
    }
    callback(UnsafeMutableRawPointer(bitPattern: handle), result)
  }
}

private struct ProbeView: View {
  @State private var count = 0

  var body: some View {
    VStack(spacing: 12) {
      Text("Count: \(count)")
      Button("Increment") { count += 1 }
    }
  }
}

private final class ProbeBackend: RenderBackend {
  var tapHandler: ((NodeID) -> Void)?
  var needsRenderCommands: Bool { false }
  func perform(_ commands: [RenderCommand]) {}
}

@MainActor
private let renderer = Renderer(
  backend: ProbeBackend(), root: AnyView(ProbeView()), size: Size(width: 320, height: 200))

// EntryAbility and ArkUI invoke these C entry points synchronously on the UI thread.
@MainActor @_cdecl("swift_render_probe")
public func swiftRenderProbe(_ tap: Bool) -> Int32 {
  renderer.mount()
  guard let before = renderer.tree else { return -1 }
  if tap {
    guard let button = find(before, kind: .button), button.frame.height > 0 else { return -2 }
    renderer.performTap(button.id)
  }
  guard let root = renderer.tree, let text = find(root, kind: .text), text.frame.height > 0,
        let count = Int32(text.props.text.dropFirst("Count: ".count))
  else { return -3 }
  return count
}

private func find(_ node: Element, kind: ElementKind) -> Element? {
  if node.kind == kind { return node }
  for child in node.children {
    if let found = find(child, kind: kind) { return found }
  }
  return nil
}

@MainActor @_cdecl("swift_visit_probe_controls")
public func swiftVisitProbeControls(
  _ context: UnsafeMutableRawPointer?,
  _ visit: @convention(c) (UnsafeMutableRawPointer?, Int32, Int, UnsafePointer<CChar>,
                         Double, Double, Double, Double) -> Void
) {
  renderer.mount()
  guard let tree = renderer.tree else { return }
  func walk(_ node: Element) {
    if node.kind == .text || node.kind == .button {
      let frame = node.frame
      node.props.text.withCString {
        visit(context, node.kind == .button ? 1 : 0, node.id.rawValue, $0,
              frame.minX, frame.minY, frame.width, frame.height)
      }
    }
    for child in node.children { walk(child) }
  }
  walk(tree)
}

@MainActor @_cdecl("swift_tap_probe_control")
public func swiftTapProbeControl(_ id: Int) {
  renderer.performTap(NodeID(rawValue: id))
}
