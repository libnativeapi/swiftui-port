/// Hoist presentations above scroll clipping while preserving the anchor's layout.

import Foundation
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public enum PopoverAttachmentAnchor {
  case rect(RectAnchor)
  case point(UnitPoint)
}
public enum RectAnchor { case bounds }
public struct PresentationBackgroundInteraction {
  let enabled: Bool
  public static let enabled = Self(enabled: true)
  public static let disabled = Self(enabled: false)
  public static let automatic = Self.disabled
}
extension View {
  public func presentationBackgroundInteraction(_ interaction: PresentationBackgroundInteraction)
    -> some View
  {
    TransformView(content: self) { $0.props.presentationBackgroundEnabled = interaction.enabled }
  }
}
extension View {
  public func popover<Panel: View>(
    isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
    arrowEdge: Edge = .top, @ViewBuilder content: () -> Panel
  ) -> some View {
    PopoverView(content: self, panel: content(), isPresented: isPresented, edge: arrowEdge)
  }
}
private struct PopoverView<Content: View, Panel: View>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content, panel: Panel
  let isPresented: Binding<Bool>
  let edge: Edge
  var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var children = [_render(content, path: path.appending(index: 0))]
    if isPresented.wrappedValue { children.append(_render(panel, path: path.appending(index: 1))) }
    var element = Element(kind: .presentation, children: children)
    element.presentationEdge = edge
    element.dismissPresentation = { isPresented.wrappedValue = false }
    return element
  }
}
func resolvePresentations(_ root: Element, in size: Size) -> Element {
  var panels: [Element] = []
  var blocksBackground = false
  func collect(_ node: Element) -> Element {
    if !node.hasPresentation { return node }
    var node = node
    node.children = node.children.map(collect)
    if node.kind == .presentation && node.children.count > 1 {
      var panel = node.children.removeLast()
      blocksBackground = blocksBackground || !panel.props.presentationBackgroundEnabled
      if node.dismissOnAction {
        func dismissAfterAction(_ panel: inout Element) {
          if let action = panel.action {
            let dismiss = node.dismissPresentation
            panel.action = {
              action()
              dismiss?()
            }
          }
          for i in panel.children.indices { dismissAfterAction(&panel.children[i]) }
        }
        dismissAfterAction(&panel)
      }
      let natural = LayoutEngine().measuredSize(of: panel)
      // The layout pass has already used the backend's text metrics.
      let width = panel.frame.width > 0 ? panel.frame.width : natural.width
      let height = panel.frame.height > 0 ? panel.frame.height : natural.height
      let anchor = node.frame
      let edge = node.presentationEdge ?? .top
      var x = anchor.minX
      var y = anchor.maxY + 4
      if edge == .bottom { y = anchor.minY - height - 4 }
      if edge == .leading {
        x = anchor.maxX + 4
        y = anchor.minY
      }
      if edge == .trailing {
        x = anchor.minX - width - 4
        y = anchor.minY
      }
      if let point = node.presentationPoint {
        x = anchor.minX + point.x
        y = anchor.minY + point.y
      }
      if y + height > size.height && anchor.minY > height { y = anchor.minY - height - 4 }
      if y < 0 && anchor.maxY + height < size.height { y = anchor.maxY + 4 }
      x = max(4, min(x, size.width - width - 4))
      y = max(4, min(y, size.height - height - 4))
      func translate(_ node: inout Element, dx: Double, dy: Double) {
        node.frame.origin.x += dx
        node.frame.origin.y += dy
        for i in node.children.indices { translate(&node.children[i], dx: dx, dy: dy) }
      }
      translate(&panel, dx: x - panel.frame.minX, dy: y - panel.frame.minY)
      var props = NodeProps()
      props.fillWidth = true
      props.fillHeight = true
      props.keyboardShortcut = .cancelAction
      let backdrop = Element(
        kind: .shape, props: props, frame: Rect(origin: .zero, size: size),
        action: node.dismissPresentation)
      panels += [backdrop, panel]
    }
    return node
  }
  var base = collect(root)
  if blocksBackground {
    func block(_ node: inout Element) {
      node.props.hitTesting = false
      for i in node.children.indices { block(&node.children[i]) }
    }
    block(&base)
  }
  if panels.isEmpty { return base }
  var result = Element(
    kind: .zStack, children: [base] + panels, frame: Rect(origin: .zero, size: size))
  result.hasActivePresentation = true
  return result
}
extension View {
  public func contextMenu<Menu: View>(@ViewBuilder menuItems: () -> Menu) -> some View {
    ContextMenuView(content: self, menu: menuItems())
  }
}
private struct ContextMenuView<Content: View, Menu: View>: View, _PrimitiveView {
  typealias Body = Never
  let content: Content, menu: Menu
  @State private var presented = false
  @State private var location = CGPoint.zero
  var body: Never { fatalError() }
  func _makeElement(path: ViewPath) -> Element {
    var children = [_render(content, path: path.appending(index: 0))]
    if presented { children.append(_render(menu, path: path.appending(index: 1))) }
    var element = Element(kind: .presentation, children: children)
    element.dismissOnAction = true
    element.presentationPoint = location
    element.secondaryAction = {
      location = $0
      presented = true
    }
    element.dismissPresentation = { presented = false }
    return element
  }
}
