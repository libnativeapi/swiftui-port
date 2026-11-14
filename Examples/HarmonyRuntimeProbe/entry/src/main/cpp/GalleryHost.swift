import SwiftUIRuntime

@MainActor
private var gallery: Renderer?

@MainActor @_cdecl("swift_mount_gallery")
public func swiftMountGallery(_ context: UnsafeMutableRawPointer, _ update: HarmonyUpdate,
                              _ width: Double, _ height: Double, _ pixelsPerPoint: Double) {
  let backend = HarmonyBackend(context: context, update: update, pixelsPerPoint: pixelsPerPoint)
  let renderer = Renderer(
    backend: backend, root: AnyView(AppView(page: "button")),
    size: Size(width: width, height: height),
    layoutEngine: LayoutEngine(textMeasurer: backend.measureText))
  gallery = renderer
  renderer.mount()
}

@MainActor @_cdecl("swift_resize_gallery")
public func swiftResizeGallery(_ width: Double, _ height: Double) {
  gallery?.resize(to: Size(width: width, height: height))
}

@MainActor @_cdecl("swift_gallery_event")
public func swiftGalleryEvent(_ id: Int, _ event: Int32, _ text: UnsafePointer<CChar>?) {
  guard let gallery else { return }
  let id = NodeID(rawValue: id)
  switch event {
  case 1: gallery.performTap(id)
  case 2, 3: gallery.interact(id, .hover(event == 2))
  case 4, 5: gallery.interact(id, .pressed(event == 4))
  case 7: gallery.input(id: id, event: 7, text: text.map(String.init(cString:)) ?? "")
  case 8, 9: gallery.interact(id, .focus(event == 8))
  default: break
  }
}

@MainActor @_cdecl("swift_unmount_gallery")
public func swiftUnmountGallery() {
  gallery = nil
}
