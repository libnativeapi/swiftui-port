import Foundation

import NativeAPI

/// The real backend: maps engine elements onto nativeapi's native views.
///
/// VStack/HStack become `View` containers with row/column layout, `Text`
/// becomes `Label`, `Button` becomes `Button`, and padding becomes a plain
/// container with padding. The engine's reference frames are used for the root
/// only; nested frames are left to nativeapi's own layout pass, which is the
/// authoritative one at runtime.
import SwiftUIRuntime

public final class NativeViewBackend: RenderBackend {
  public var tapHandler: ((NodeID) -> Void)?
  public var onResize: ((SwiftUIRuntime.Size) -> Void)?

  private let window: NativeAPI.Window
  private let contentView: NativeAPI.View

  private var handles: [NodeID: NativeAPI.View] = [:]
  private var kinds: [NodeID: ElementKind] = [:]
  private var propsByID: [NodeID: NodeProps] = [:]
  private var childrenByID: [NodeID: [NodeID]] = [:]
  private var parentByID: [NodeID: NodeID] = [:]
  private var listeners: [NodeID: ListenerId] = [:]
  private var rootID: NodeID?
  private var windowListener: ListenerId?

  public init?(window: NativeAPI.Window) {
    guard let contentView = window.contentView else { return nil }
    self.window = window
    self.contentView = contentView
    self.windowListener = window.addListener { [weak self] event in
      guard case .resized = event, let self else { return }
      // The event payload is the frame size (decorations included); the
      // renderer lays out the content area, so read that instead.
      let content = self.window.contentSize
      self.onResize?(SwiftUIRuntime.Size(width: content.width, height: content.height))
    }
  }

  deinit {
    if let windowListener {
      _ = window.removeListener(windowListener)
    }
  }

  public func perform(_ commands: [RenderCommand]) {
    for command in commands {
      apply(command)
    }
  }

  // MARK: - Command application

  private func apply(_ command: RenderCommand) {
    switch command {
    case .create(let id, let kind, let props):
      create(id: id, kind: kind, props: props)
    case .insert(let id, let parent, let index):
      insert(id: id, parent: parent, index: index)
    case .remove(let id):
      remove(id: id)
    case .move(let id, let parent, let index):
      move(id: id, parent: parent, index: index)
    case .setProps(let id, let props):
      guard let view = handles[id], let kind = kinds[id] else { return }
      update(view: view, kind: kind, props: props, id: id)
    case .setFrame(let id, let frame):
      guard id == rootID, let view = handles[id] else { return }
      view.setFrame(
        NativeAPI.Rectangle(
          x: frame.origin.x,
          y: frame.origin.y,
          width: frame.size.width,
          height: frame.size.height
        )
      )
    }
  }

  private func create(id: NodeID, kind: ElementKind, props: NodeProps) {
    let view: NativeAPI.View
    switch kind {
    case .text:
      guard let label = NativeAPI.Label.create(props.text) else { return }
      view = label
    case .button:
      guard let button = NativeAPI.Button.create(props.text) else { return }
      view = button
      listeners[id] = button.addListener { [weak self] event in
        guard case .buttonClicked = event else { return }
        self?.tapHandler?(id)
      }
    case .container, .padding, .frame, .empty:
      guard let container = NativeAPI.View.create() else { return }
      view = container
    case .layer, .shape, .styledButton, .presentation, .grid, .zStack, .scroll, .geometry,
      .customLayout, .textField, .image, .path, .gradient:
      preconditionFailure(
        "Custom drawing and ButtonStyle require WindowsDrawingBackend; this backend supports native controls only"
      )
    case .spacer:
      guard let spacer = NativeAPI.View.create() else { return }
      spacer.setFlex(1)
      view = spacer
    case .fragment:
      return
    }

    handles[id] = view
    kinds[id] = kind
    propsByID[id] = props
    update(view: view, kind: kind, props: props, id: id)
  }

  private func update(view: NativeAPI.View, kind: ElementKind, props: NodeProps, id: NodeID) {
    let previous = propsByID[id]
    // Publish the new props before alignment is propagated to children, so a
    // stack alignment change takes effect in the same update.
    propsByID[id] = props

    view.setVisible(props.visible)
    view.setEnabled(props.enabled)
    view.setBackgroundColor(props.background?.nativeColor ?? NativeAPI.Color.transparent)

    if props.frameWidth != nil || props.frameHeight != nil {
      view.setPreferredSize(
        NativeAPI.Size(width: props.frameWidth ?? 0, height: props.frameHeight ?? 0)
      )
    } else if previous?.frameWidth != nil || previous?.frameHeight != nil {
      // nativeapi treats 0 as "use the intrinsic size", which is how a
      // removed .frame modifier is undone.
      view.setPreferredSize(NativeAPI.Size(width: 0, height: 0))
    }

    switch kind {
    case .text:
      guard let label = view as? NativeAPI.Label else { return }
      label.setText(props.text)
      if let foreground = props.foreground {
        label.setTextColor(foreground.nativeColor)
      } else if previous?.foreground != nil {
        // There is no "restore platform default" API; black is the neutral
        // fallback when a previously colored Text loses its color.
        label.setTextColor(.black)
      }
    case .button:
      // nativeapi's Button exposes text but not a text color; .foregroundColor
      // is documented as Text-only in v0.1.
      (view as? NativeAPI.Button)?.setText(props.text)
    case .container(let axis):
      view.setLayout(axis == .horizontal ? .row : .column)
      view.setSpacing(props.spacing)
      view.setPadding(props.padding.nativeInsets)
      view.setFlex(props.flex)
      applyAlignmentToChildren(parent: id)
    case .padding, .frame:
      view.setLayout(.column)
      view.setSpacing(0)
      view.setPadding(props.padding.nativeInsets)
      view.setFlex(props.flex)
      applyAlignmentToChildren(parent: id)
    case .spacer:
      view.setFlex(1)
      view.setAlignment(.stretch)
    case .empty, .fragment, .shape, .layer, .styledButton, .presentation, .grid, .zStack, .scroll,
      .geometry, .customLayout, .textField, .image, .path, .gradient:
      break
    }
  }

  private func insert(id: NodeID, parent: NodeID?, index: Int) {
    guard let view = handles[id] else { return }
    let parentView = parent.flatMap { handles[$0] } ?? contentView
    parentView.insertSubview(CUnsignedLong(index), subview: view)

    if let parent {
      childrenByID[parent, default: []].insert(id, at: index)
      parentByID[id] = parent
    } else {
      rootID = id
    }
    applyAlignment(to: id, parent: parent)
  }

  private func remove(id: NodeID) {
    guard let view = handles[id] else { return }
    detachFromParent(id: id, view: view)
    disposeSubtree(id)
  }

  private func move(id: NodeID, parent: NodeID?, index: Int) {
    guard let view = handles[id] else { return }

    if let oldParent = parentByID[id], let oldParentView = handles[oldParent] {
      _ = oldParentView.removeSubview(view)
      childrenByID[oldParent]?.removeAll { $0 == id }
      parentByID.removeValue(forKey: id)
    } else {
      _ = contentView.removeSubview(view)
    }

    let parentView = parent.flatMap { handles[$0] } ?? contentView
    parentView.insertSubview(CUnsignedLong(index), subview: view)

    if let parent {
      childrenByID[parent, default: []].insert(id, at: index)
      parentByID[id] = parent
    } else {
      rootID = id
    }
    applyAlignment(to: id, parent: parent)
  }

  private func detachFromParent(id: NodeID, view: NativeAPI.View) {
    if let parent = parentByID[id], let parentView = handles[parent] {
      _ = parentView.removeSubview(view)
      childrenByID[parent]?.removeAll { $0 == id }
      parentByID.removeValue(forKey: id)
    } else {
      _ = contentView.removeSubview(view)
      if rootID == id {
        rootID = nil
      }
    }
  }

  private func disposeSubtree(_ id: NodeID) {
    for child in childrenByID[id] ?? [] {
      disposeSubtree(child)
    }
    if let listener = listeners.removeValue(forKey: id), let view = handles[id] {
      _ = view.removeListener(listener)
    }
    handles.removeValue(forKey: id)?.dispose()
    kinds.removeValue(forKey: id)
    propsByID.removeValue(forKey: id)
    childrenByID.removeValue(forKey: id)
    parentByID.removeValue(forKey: id)
  }

  // MARK: - Alignment

  private func applyAlignment(to childID: NodeID, parent: NodeID?) {
    guard let parent,
      let parentKind = kinds[parent],
      let parentProps = propsByID[parent],
      let childView = handles[childID]
    else { return }

    let alignment: NativeAPI.ViewAlignment?
    switch parentKind {
    case .container(.vertical):
      switch parentProps.horizontalAlignment {
      case .leading: alignment = .start
      case .center: alignment = .center
      case .trailing: alignment = .end
      }
    case .container(.horizontal):
      switch parentProps.verticalAlignment {
      case .top: alignment = .start
      case .center: alignment = .center
      case .bottom: alignment = .end
      }
    case .padding:
      alignment = .stretch
    default:
      alignment = nil
    }

    if let alignment {
      childView.setAlignment(alignment)
    }

    // A container inside a padding wrapper is the content of that wrapper. Give
    // it the wrapper's leftover space so a root VStack fills the window instead
    // of shrinking to its intrinsic height.
    if case .padding = parentKind {
      switch kinds[childID] {
      case .container, .padding:
        childView.setFlex(1)
      default:
        break
      }
    }
  }

  private func applyAlignmentToChildren(parent: NodeID) {
    for child in childrenByID[parent] ?? [] {
      applyAlignment(to: child, parent: parent)
    }
  }
}
extension SwiftUIRuntime.Color {
  var nativeColor: NativeAPI.Color {
    NativeAPI.Color.fromRgba(
      UInt8(clamping: Int((red * 255).rounded())),
      green: UInt8(clamping: Int((green * 255).rounded())),
      blue: UInt8(clamping: Int((blue * 255).rounded())),
      alpha: UInt8(clamping: Int((opacity * 255).rounded()))
    )
  }
}
extension SwiftUIRuntime.EdgeInsets {
  var nativeInsets: NativeAPI.EdgeInsets {
    NativeAPI.EdgeInsets(top: top, right: trailing, bottom: bottom, left: leading)
  }
}
