#if os(Linux)
import CGTK3
import Foundation
import SwiftUIRuntime

final class LinuxDrawing {
  private struct TextKey: Hashable {
    let text: String
    let font: Font
    var spacing = 0.0
    var underline = false
    var tracking = 0.0
  }
  private var measured: [TextKey: SwiftUIRuntime.Size] = [:]
  private var layouts: [TextKey: OpaquePointer] = [:]
  private let textContext = pango_font_map_create_context(pango_cairo_font_map_get_default())

  deinit {
    for layout in layouts.values { g_object_unref(UnsafeMutableRawPointer(layout)) }
    if let textContext { g_object_unref(UnsafeMutableRawPointer(textContext)) }
  }
  struct Motion {
    let from: DrawingValues
    let animation: Animation
    let start: TimeInterval

    func apply(to props: inout NodeProps, now: TimeInterval) -> CGPoint {
      let elapsed = max(0, (now - start) / animation.duration)
      var progress = animation.repeats ? elapsed.truncatingRemainder(dividingBy: 1) : min(1, elapsed)
      if animation.autoreverses && Int(elapsed) % 2 == 1 { progress = 1 - progress }
      func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * progress }
      props.rotation = mix(from.rotation, props.rotation)
      props.scaleX = mix(from.scaleX, props.scaleX)
      props.scaleY = mix(from.scaleY, props.scaleY)
      props.opacity = mix(from.opacity, props.opacity)
      return CGPoint(x: mix(from.offsetX, props.offsetX) - props.offsetX,
                     y: mix(from.offsetY, props.offsetY) - props.offsetY)
    }
  }

  struct DrawingValues: Equatable {
    let rotation, scaleX, scaleY, opacity, offsetX, offsetY: Double

    init(_ props: NodeProps) {
      rotation = props.rotation
      scaleX = props.scaleX
      scaleY = props.scaleY
      opacity = props.opacity
      offsetX = props.offsetX
      offsetY = props.offsetY
    }
  }

  func measure(_ text: String, font: Font) -> SwiftUIRuntime.Size {
    let key = TextKey(text: text, font: font)
    if let size = measured[key] { return size }
    guard let layout = textLayout(key) else { return .zero }
    var width: Int32 = 0
    var height: Int32 = 0
    pango_layout_get_pixel_size(layout, &width, &height)
    let size = SwiftUIRuntime.Size(width: Double(width), height: Double(height))
    if measured.count >= 2048 { measured.removeAll(keepingCapacity: true) }
    measured[key] = size
    return size
  }

  private func configure(_ layout: OpaquePointer, text: String, font: Font, spacing: Double) {
    guard let description = pango_font_description_new() else { return }
    defer { pango_font_description_free(description) }
    let family: String
    switch font.family {
    case "Segoe UI", "-apple-system", "system-ui": family = "Sans"
    case "Consolas": family = "Monospace"
    case "Georgia": family = "Serif"
    default: family = font.family
    }
    pango_font_description_set_family(description, family)
    pango_font_description_set_absolute_size(description, Double(font.size) * Double(PANGO_SCALE))
    pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(max(100, min(900, font.weight.value)))))
    pango_layout_set_font_description(layout, description)
    pango_layout_set_text(layout, text, -1)
    pango_layout_set_spacing(layout, Int32(clamping: Int(spacing * Double(PANGO_SCALE))))
  }

  func paint(_ node: Element, in context: OpaquePointer, clip: Rect, damage: Rect,
                    motions: [NodeID: Motion], now: TimeInterval, inheritedOpacity: Double = 1) {
    var props = node.props
    let translation = motions[node.id]?.apply(to: &props, now: now) ?? .zero
    let frame = node.frame
    guard props.visible, props.opacity > 0, frame.width.isFinite, frame.height.isFinite else { return }
    // The runtime resolves cumulative opacity. Cairo applies the relative
    // opacity of this node to the group that holds its drawing and children.
    let opacity = min(1, props.opacity / inheritedOpacity)
    let area = frame.intersection(clip)
    if props.clipped && area.isEmpty { return }
    if node.children.isEmpty && area.isEmpty && props.shadows.isEmpty { return }

    let transformed = translation != .zero || props.rotation != 0 || props.scaleX != 1 || props.scaleY != 1
    if !transformed && props.shadows.isEmpty && frame.intersection(damage).isEmpty
      && (props.clipped || (node.children.isEmpty && props.shadows.isEmpty)) { return }
    let usesClip = props.clipped || node.clipPathBuilder != nil
    if transformed || usesClip { cairo_save(context) }
    defer { if transformed || usesClip { cairo_restore(context) } }
    if translation != .zero { cairo_translate(context, translation.x, translation.y) }

    if props.rotation != 0 || props.scaleX != 1 || props.scaleY != 1 {
      cairo_translate(context, frame.minX + frame.width / 2, frame.minY + frame.height / 2)
      cairo_rotate(context, props.rotation * .pi / 180)
      cairo_scale(context, props.scaleX, props.scaleY)
      cairo_translate(context, -frame.minX - frame.width / 2, -frame.minY - frame.height / 2)
    }
    for shadow in props.shadows where shadow.color.opacity > 0 {
      let layers = max(1, min(12, Int(ceil(shadow.radius))))
      for layer in (0..<layers).reversed() {
        let spread = Double(layer) / 2
        let rect = Rect(x: frame.minX + shadow.x - spread, y: frame.minY + shadow.y - spread,
                        width: frame.width + spread * 2, height: frame.height + spread * 2)
        shape(context, Path(roundedRect: rect.cgRect, cornerRadius: props.cornerRadius + spread),
              fill: shadow.color.opacity(1 / Double(layers)), stroke: .clear, width: 0)
      }
    }
    if props.clipped {
      add(Path(roundedRect: frame.cgRect, cornerRadius: props.cornerRadius), to: context)
      cairo_clip(context)
    }
    if let builder = node.clipPathBuilder {
      let mask = builder(CGRect(origin: .zero, size: frame.cgRect.size))
      add(mask.transformed(x: frame.minX, y: frame.minY), to: context)
      cairo_clip(context)
    }

    if opacity < 1 { cairo_push_group(context) }
    if let builder = node.pathBuilder {
      shape(context, builder(frame.cgRect), fill: props.background ?? .clear,
            stroke: props.borderColor, width: props.borderWidth, dash: props.dash)
    } else if node.kind == .path {
      shape(context, props.path.transformed(x: frame.minX, y: frame.minY),
            fill: props.background ?? .clear, stroke: props.borderColor, width: props.borderWidth, dash: props.dash)
    } else if props.background != nil || props.borderWidth > 0 {
      shape(context, Path(roundedRect: frame.cgRect, cornerRadius: props.cornerRadius),
            fill: props.background ?? .clear, stroke: props.borderColor, width: props.borderWidth)
    }
    if node.kind == .gradient, let gradient = props.gradient {
      let pattern = cairo_pattern_create_linear(
        frame.minX + gradient.start.x * frame.width, frame.minY + gradient.start.y * frame.height,
        frame.minX + gradient.end.x * frame.width, frame.minY + gradient.end.y * frame.height)
      if let pattern {
        for (index, color) in gradient.colors.enumerated() {
          cairo_pattern_add_color_stop_rgba(pattern, Double(index) / Double(max(1, gradient.colors.count - 1)),
                                           color.red, color.green, color.blue, color.opacity)
        }
        cairo_set_source(context, pattern)
        cairo_rectangle(context, frame.minX, frame.minY, frame.width, frame.height)
        cairo_fill(context)
        cairo_pattern_destroy(pattern)
      }
    }
    if node.kind == .image { image(node, in: context) }
    if node.kind == .text || node.kind == .button { text(node, in: context) }
    for child in Self.orderedChildren(node) {
      paint(child, in: context, clip: props.clipped ? area : clip, damage: transformed ? clip : damage,
            motions: motions, now: now,
            inheritedOpacity: node.props.opacity)
    }
    if node.kind == .scroll, props.showsScrollIndicators, let content = node.children.first {
      let color = (props.foreground ?? .gray).opacity(0.28)
      if content.frame.height > frame.height && frame.height > 0 {
        let height = max(20, frame.height * frame.height / content.frame.height)
        let y = frame.minY + props.scrollOffset.y / (content.frame.height - frame.height) * (frame.height - height)
        shape(context, Path(roundedRect: CGRect(x: frame.maxX - 5, y: y, width: 4, height: height), cornerRadius: 2),
              fill: color, stroke: .clear, width: 0)
      }
      if content.frame.width > frame.width && frame.width > 0 {
        let width = max(20, frame.width * frame.width / content.frame.width)
        let x = frame.minX + props.scrollOffset.x / (content.frame.width - frame.width) * (frame.width - width)
        shape(context, Path(roundedRect: CGRect(x: x, y: frame.maxY - 5, width: width, height: 4), cornerRadius: 2),
              fill: color, stroke: .clear, width: 0)
      }
    }
    if opacity < 1 {
      cairo_pop_group_to_source(context)
      cairo_paint_with_alpha(context, opacity)
    }
  }

  private func textLayout(_ key: TextKey) -> OpaquePointer? {
    if let layout = layouts[key] { return layout }
    guard let textContext, let layout = pango_layout_new(textContext) else { return nil }
    configure(layout, text: key.text, font: key.font, spacing: key.spacing)
    if key.underline || key.tracking != 0, let attributes = pango_attr_list_new() {
      if key.underline { pango_attr_list_insert(attributes, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE)) }
      if key.tracking != 0 {
        pango_attr_list_insert(attributes, pango_attr_letter_spacing_new(Int32(clamping: Int(key.tracking * Double(PANGO_SCALE)))))
      }
      pango_layout_set_attributes(layout, attributes)
      pango_attr_list_unref(attributes)
    }
    if layouts.count >= 1024 {
      for old in layouts.values { g_object_unref(UnsafeMutableRawPointer(old)) }
      layouts.removeAll(keepingCapacity: true)
    }
    layouts[key] = layout
    return layout
  }

  private func text(_ node: Element, in context: OpaquePointer) {
    let props = node.props
    let frame = node.frame
    let key = TextKey(text: props.renderedText ?? props.text, font: props.font ?? .body,
                      spacing: props.lineSpacing, underline: props.underline, tracking: props.tracking)
    guard let layout = textLayout(key) else { return }
    source(context, props.foreground ?? .black)
    if node.kind == .button {
      var width: Int32 = 0, height: Int32 = 0
      pango_layout_get_pixel_size(layout, &width, &height)
      cairo_move_to(context, frame.minX + (frame.width - Double(width)) / 2,
                    frame.minY + (frame.height - Double(height)) / 2)
    } else {
      cairo_move_to(context, frame.minX, frame.minY)
    }
    pango_cairo_show_layout(context, layout)
  }

  private func image(_ node: Element, in context: OpaquePointer) {
    let frame = node.frame
    guard frame.width > 0, frame.height > 0 else { return }
    let path = node.props.imagePath
    if path.lowercased().hasSuffix(".svg"), let image = VectorImage.load(path),
       image.bounds.width > 0, image.bounds.height > 0 {
      let scale = min(frame.width / image.bounds.width, frame.height / image.bounds.height)
      let x = frame.minX + (frame.width - image.bounds.width * scale) / 2 - image.bounds.minX * scale
      let y = frame.minY + (frame.height - image.bounds.height * scale) / 2 - image.bounds.minY * scale
      for path in image.paths {
        shape(context, path.transformed(x: x, y: y, sx: scale, sy: scale),
              fill: node.props.foreground ?? .black, stroke: .clear, width: 0)
      }
    } else if let pixels = gdk_pixbuf_new_from_file_at_scale(path, Int32(clamping: Int(frame.width)),
                                                             Int32(clamping: Int(frame.height)), 1, nil) {
      defer { g_object_unref(UnsafeMutableRawPointer(pixels)) }
      gdk_cairo_set_source_pixbuf(context, pixels, frame.minX, frame.minY)
      cairo_paint(context)
    }
  }

  private func shape(_ context: OpaquePointer, _ path: Path, fill: Color, stroke: Color,
                            width: Double, dash: [Double] = []) {
    add(path, to: context)
    if fill.opacity > 0 {
      source(context, fill)
      cairo_fill_preserve(context)
    }
    if width > 0, stroke.opacity > 0 {
      source(context, stroke)
      cairo_set_line_width(context, width)
      dash.withUnsafeBufferPointer { cairo_set_dash(context, $0.baseAddress, Int32($0.count), 0) }
      cairo_stroke(context)
    } else {
      cairo_new_path(context)
    }
  }

  private func add(_ path: Path, to context: OpaquePointer) {
    cairo_new_path(context)
    let values = path.commands
    var index = 0
    while index < values.count {
      switch values[index] {
      case 0 where index + 2 < values.count:
        cairo_move_to(context, values[index + 1], values[index + 2])
        index += 3
      case 1 where index + 2 < values.count:
        cairo_line_to(context, values[index + 1], values[index + 2])
        index += 3
      case 2 where index + 6 < values.count:
        cairo_curve_to(context, values[index + 1], values[index + 2], values[index + 3],
                       values[index + 4], values[index + 5], values[index + 6])
        index += 7
      case 3:
        cairo_close_path(context)
        index += 1
      default: return
      }
    }
  }

  private func source(_ context: OpaquePointer, _ color: Color) {
    cairo_set_source_rgba(context, color.red, color.green, color.blue, color.opacity)
  }

  static func orderedChildren(_ node: Element) -> [Element] {
    let children = node.kind == .layer && node.props.layerBehind ? Array(node.children.reversed()) : node.children
    if !children.contains(where: { $0.props.zIndex != 0 }) { return children }
    return children.enumerated().sorted {
      $0.element.props.zIndex == $1.element.props.zIndex
        ? $0.offset < $1.offset : $0.element.props.zIndex < $1.element.props.zIndex
    }.map(\.element)
  }
}

extension Rect {
  var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
  var isEmpty: Bool { width <= 0 || height <= 0 }

  func intersection(_ other: Rect) -> Rect {
    let x = max(minX, other.minX)
    let y = max(minY, other.minY)
    return Rect(x: x, y: y, width: max(0, min(maxX, other.maxX) - x),
                height: max(0, min(maxY, other.maxY) - y))
  }
}
#endif
