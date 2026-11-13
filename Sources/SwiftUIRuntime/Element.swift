/// A stable handle to one mounted element.
///
/// IDs are allocated by the renderer and survive re-evaluation when an element
/// keeps its identity. The native backend uses them as keys into its view map.

/// What an element is.
///
/// Kind is part of an element's diff identity: changing a `Text` into a
/// `Button` replaces the native control.

/// Everything about an element that can change without replacing the native
/// view. The native backend diffs these values; `.id(_:)` and `.onTapGesture`
/// are carried separately.

/// The engine's render tree node.

/// Structural identity used by the diff.
///
/// Keys are scoped to a sibling list. An explicit `.id` wins; otherwise the
/// child's position and kind determine identity. NodeID is the global handle.

/// Removes fragments and empty views from the tree and gives every child a
/// contiguous sibling index.

/// Assigns diff keys top-down and children left-to-right.

/// Resolves inherited `.foregroundColor` and `.disabled` values.
///
/// Foreground is inherited by every descendant; a value set on a descendant
/// wins. Disabled has the same shape, with `.disabled(false)` re-enabling a
/// subtree. This happens before diffing so the backend only sees effective
/// values.

/// Collects the current tap handlers keyed by node id.
import Foundation

public struct NodeID: Hashable, Comparable, CustomStringConvertible {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String { "#\(rawValue)" }
}
public enum ElementKind: Equatable, CustomStringConvertible {
  /// A transparent fragment produced by a multi-child builder block. It never
  /// reaches a backend; containers flatten it away.
  case fragment
  /// A native container with `row` or `column` layout.
  case container(Axis)
  /// The element created by `.padding(...)`. It is a plain native container
  /// with padding and one stretched child.
  case padding
  case frame, layer, shape, styledButton
  case presentation, grid, zStack, scroll, geometry, customLayout, textField, image, path, gradient
  case text
  case button
  case spacer
  case empty

  var identityName: String {
    switch self {
    case .fragment: return "Fragment"
    case .container(.horizontal): return "HStack"
    case .container(.vertical): return "VStack"
    case .padding: return "Padding"
    case .presentation: return "Popover"
    case .grid: return "Grid"
    case .zStack: return "ZStack"
    case .scroll: return "ScrollView"
    case .geometry: return "GeometryReader"
    case .customLayout: return "Layout"
    case .textField: return "TextField"
    case .image: return "Image"
    case .path: return "Path"
    case .gradient: return "Gradient"
    case .frame: return "Frame"
    case .layer: return "Layer"
    case .shape: return "Shape"
    case .styledButton: return "StyledButton"
    case .text: return "Text"
    case .button: return "Button"
    case .spacer: return "Spacer"
    case .empty: return "Empty"
    }
  }

  public var description: String { identityName }
}
public struct NodeProps: Equatable {
  public var text: String = ""
  public var renderedText: String? = nil
  public var idealWidth: Double? = nil, idealHeight: Double? = nil
  public var tracking: Double = 0
  public var textAlignment: TextAlignment = .leading
  public var truncationMode: Text.TruncationMode = .tail
  public var dash: [Double] = []
  public var offsetX: Double = 0, offsetY: Double = 0
  public var scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0
  public var zIndex: Double = 0
  public var underline = false, aspectFit = false
  public var aspectRatio: Double? = nil
  public var transition: AnyTransition? = nil
  public var hitTesting = true
  public var fixedWidth = false, fixedHeight = false
  public var showsScrollIndicators = true
  public var gridUnsizedAxes: Axis.Set = []
  public var scrollAxes: Axis.Set = .vertical
  public var scrollOffset = Point.zero
  public var placeholder = ""
  public var secure = false, multiline = false
  public var imagePath = ""
  public var imageTemplate = false
  public var path = Path()
  public var gradient: LinearGradient.Data? = nil
  public var accessibilityLabel = "", accessibilityValue = "", accessibilityHidden = false
  public var keyboardShortcut: KeyboardShortcut? = nil
  public var coordinateSpace: AnyHashable? = nil
  public var focusable = false
  public var accessibilityTraits = 0

  public var font: Font? = nil
  public var lineLimit: Int? = nil
  public var lineSpacing: Double = 0
  public var minWidth: Double? = nil
  public var minHeight: Double? = nil
  public var maxWidth: Double? = nil
  public var maxHeight: Double? = nil
  public var fillWidth = false
  public var fillHeight = false
  public var alignment: Alignment = .center
  public var layerBehind = false
  public var cornerRadius: Double = 0
  public var hitRadius: Double = 0
  public var clipped = false
  public var borderColor: Color = .clear
  public var borderWidth: Double = 0
  public var opacity: Double = 1
  public var shadows: [Shadow] = []
  public var animation: Animation? = nil
  public var presentationBackgroundEnabled = false
  public var focusRequested = false
  public var help = ""
  /// Effective visibility. `.hidden()` sets this to false.
  public var visible: Bool = true
  /// Effective enabled state, after `.disabled(...)` inheritance is resolved.
  public var enabled: Bool = true
  /// The explicit value from `.disabled(...)`, kept so environment resolution
  /// can distinguish "not set" from "set to false".
  public var disabledOverride: Bool? = nil
  public var background: Color? = nil
  /// Effective foreground color, after environment inheritance is resolved.
  public var foreground: Color? = nil
  public var padding: EdgeInsets = .zero
  public var frameWidth: Double? = nil
  public var frameHeight: Double? = nil
  public var spacing: Double = 0
  public var horizontalAlignment: HorizontalAlignment = .center
  public var verticalAlignment: VerticalAlignment = .center
  /// Main-axis share for `Spacer`; 0 means fixed.
  public var flex: Double = 0

  public init() {}
}
public struct Element {
  public internal(set) var id: NodeID
  public var kind: ElementKind
  public var props: NodeProps
  public var children: [Element]
  public internal(set) var frame: Rect

  /// Diff identity, assigned after evaluation.
  var key: ElementKey = .root
  /// Assigned only within one layout pass, including dynamically built geometry.
  var layoutID: Int = 0
  var evaluationID: Int = 0
  var evaluationRevision: Int = 0
  var reusesLayout = false
  var hasDynamicLayout = false
  var hasPresentation = false
  var hasActivePresentation = false
  var hasPreferences = false
  var layoutContext: [AnyHashable: CGPoint] = [:]
  var customLayoutFrames: [CGRect] = []
  var geometrySnapshot: GeometrySnapshot?
  /// The value from `.id(_:)`, if any.
  var explicitID: AnyHashable? = nil
  /// The action of a `Button`, or of `.onTapGesture` on a Button.
  var action: (() -> Void)? = nil
  var hoverAction: ((Bool) -> Void)? = nil
  var focusAction: ((Bool) -> Void)? = nil
  public var pathBuilder: ((CGRect) -> Path)? = nil
  public var clipPathBuilder: ((CGRect) -> Path)? = nil
  var horizontalGuide: ((ViewDimensions) -> CGFloat)? = nil
  var verticalGuide: ((ViewDimensions) -> CGFloat)? = nil
  var preferences: [ObjectIdentifier: PreferenceValue] = [:]
  var preferenceAction: (([ObjectIdentifier: PreferenceValue]) -> Void)? = nil
  var geometryBuilder: ((CGRect) -> Element)? = nil
  var layout: (any _LayoutBridge)? = nil
  var textAction: ((String) -> Void)? = nil
  var submitAction: (() -> Void)? = nil
  var dragAction: ((DragGesture.Value, Bool) -> Void)? = nil
  var doubleTapAction: (() -> Void)? = nil
  var keyAction: ((KeyPress) -> KeyPress.Result)? = nil
  var scrollAction: ((Point) -> Void)? = nil
  // Only ScrollView's private offset can use the geometry-only update path.
  var scrollStateKey: StateKey? = nil
  var secondaryAction: ((CGPoint) -> Void)? = nil
  var dismissOnAction = false
  var presentationPoint: CGPoint? = nil
  var presentationEdge: Edge? = nil
  var dismissPresentation: (() -> Void)? = nil
  var pressedAction: ((Bool) -> Void)? = nil

  init(
    id: NodeID = NodeID(rawValue: 0),
    kind: ElementKind,
    props: NodeProps = NodeProps(),
    children: [Element] = [],
    frame: Rect = .zero,
    explicitID: AnyHashable? = nil,
    action: (() -> Void)? = nil
  ) {
    self.id = id
    self.kind = kind
    self.props = props
    self.children = children
    self.frame = frame
    self.explicitID = explicitID
    self.action = action
  }

  public var needsNativeFocus: Bool { props.focusable || focusAction != nil }

  package var supportsTranslation: Bool {
    if !hasDynamicLayout { return true }
    if (kind == .presentation && children.count > 1) || layout != nil
      || geometrySnapshot?.dependsOnPosition == true
    {
      return false
    }
    return children.allSatisfy(\.supportsTranslation)
  }

  public var isContainer: Bool {
    switch kind {
    case .container, .padding, .frame, .layer, .styledButton, .presentation, .grid, .zStack,
      .scroll, .geometry, .customLayout:
      return true
    default:
      return false
    }
  }
}
enum ElementKey: Hashable {
  case root
  case explicit(AnyHashable)
  case structural(String, Int)
}
func normalize(_ element: Element, previous: Element? = nil) -> Element {
  if let previous, element.evaluationID != 0,
    element.evaluationID == previous.evaluationID,
    element.evaluationRevision == previous.evaluationRevision,
    element.kind == previous.kind
  {
    return previous
  }
  var result = element
  if element.kind == .layer {
    result.children = element.children.enumerated().map { index, child in
      normalize(
        child, previous: previous.flatMap { index < $0.children.count ? $0.children[index] : nil })
    }
    return result
  }
  result.children = result.children.enumerated().flatMap { index, child -> [Element] in
    let normalized = normalize(
      child, previous: previous.flatMap { index < $0.children.count ? $0.children[index] : nil })
    switch normalized.kind {
    case .fragment:
      return normalized.children
    case .empty:
      return []
    default:
      return [normalized]
    }
  }
  if result.kind == .fragment {
    switch result.children.count {
    case 0:
      return Element(kind: .empty)
    case 1:
      return result.children[0]
    default:
      var props = NodeProps()
      props.spacing = 0
      return Element(kind: .container(.vertical), props: props, children: result.children)
    }
  }
  return result
}
func assignKeys(_ element: inout Element, index: Int = 0) {
  let expected: ElementKey =
    element.explicitID.map(ElementKey.explicit)
    ?? .structural(element.kind.identityName, index)
  if element.reusesLayout && element.key == expected { return }
  if let explicitID = element.explicitID {
    element.key = .explicit(explicitID)
  } else {
    element.key = .structural(element.kind.identityName, index)
  }
  for childIndex in element.children.indices {
    assignKeys(&element.children[childIndex], index: childIndex)
  }
}
func resolveEnvironment(
  _ element: inout Element,
  inheritedForeground: Color? = nil,
  inheritedDisabled: Bool = false,
  inheritedOpacity: Double = 1,
  inheritedVisible: Bool = true,
  inheritedLineLimit: Int? = nil,
  inheritedLineSpacing: Double = 0,
  previous: Element? = nil
) {
  let foreground = element.props.foreground ?? inheritedForeground
  let disabled = element.props.disabledOverride ?? inheritedDisabled

  element.props.foreground = foreground
  element.props.enabled = !disabled
  element.props.visible = element.props.visible && inheritedVisible
  element.props.opacity *= inheritedOpacity
  element.props.lineLimit = element.props.lineLimit ?? inheritedLineLimit
  if element.props.lineSpacing == 0 { element.props.lineSpacing = inheritedLineSpacing }

  if let previous, element.evaluationID != 0,
    element.evaluationID == previous.evaluationID,
    element.evaluationRevision == previous.evaluationRevision, !previous.hasPresentation
  {
    var oldProps = previous.props
    oldProps.renderedText = element.props.renderedText
    if oldProps == element.props {
      element = previous
      element.reusesLayout = true
      return
    }
  }

  for index in element.children.indices {
    resolveEnvironment(
      &element.children[index],
      inheritedForeground: foreground,
      inheritedDisabled: disabled,
      inheritedOpacity: element.props.opacity,
      inheritedVisible: element.props.visible,
      inheritedLineLimit: element.props.lineLimit,
      inheritedLineSpacing: element.props.lineSpacing,
      previous: previous.flatMap { index < $0.children.count ? $0.children[index] : nil }
    )
  }
}
func collectActions(_ element: Element, into actions: inout [NodeID: () -> Void]) {
  if let action = element.action {
    actions[element.id] = action
  }
  for child in element.children {
    collectActions(child, into: &actions)
  }
}
