/// A stable handle to one mounted element.
///
/// IDs are allocated by the renderer and survive re-evaluation when an element
/// keeps its identity. The native backend uses them as keys into its view map.
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

/// What an element is.
///
/// Kind is part of an element's diff identity: changing a `Text` into a
/// `Button` replaces the native control.
public enum ElementKind: Equatable, CustomStringConvertible {
  /// A transparent fragment produced by a multi-child builder block. It never
  /// reaches a backend; containers flatten it away.
  case fragment
  /// A native container with `row` or `column` layout.
  case container(Axis)
  /// The element created by `.padding(...)`. It is a plain native container
  /// with padding and one stretched child.
  case padding
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
    case .text: return "Text"
    case .button: return "Button"
    case .spacer: return "Spacer"
    case .empty: return "Empty"
    }
  }

  public var description: String { identityName }
}

/// Everything about an element that can change without replacing the native
/// view. The native backend diffs these values; `.id(_:)` and `.onTapGesture`
/// are carried separately.
public struct NodeProps: Equatable {
  public var text: String = ""
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

/// The engine's render tree node.
public struct Element {
  public internal(set) var id: NodeID
  public var kind: ElementKind
  public var props: NodeProps
  public var children: [Element]
  public internal(set) var frame: Rect

  /// Diff identity, assigned after evaluation.
  var key: ElementKey = .root
  /// The value from `.id(_:)`, if any.
  var explicitID: AnyHashable? = nil
  /// The action of a `Button`, or of `.onTapGesture` on a Button.
  var action: (() -> Void)? = nil

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

  public var isContainer: Bool {
    switch kind {
    case .container, .padding:
      return true
    default:
      return false
    }
  }
}

/// Structural identity used by the diff.
///
/// An explicit `.id` wins and is global within the tree. Otherwise the key is
/// the parent key plus the child's position and kind, which is what makes an
/// unchanged position reuse its native view.
indirect enum ElementKey: Hashable {
  case root
  case explicit(AnyHashable)
  case structural(parent: ElementKey, kind: String, index: Int)
}

/// Removes fragments and empty views from the tree and gives every child a
/// contiguous sibling index.
func normalize(_ element: Element) -> Element {
  var result = element
  result.children = result.children.flatMap { child -> [Element] in
    let normalized = normalize(child)
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

/// Assigns diff keys top-down and children left-to-right.
func assignKeys(_ element: inout Element, parent: ElementKey, index: Int) {
  if let explicitID = element.explicitID {
    element.key = .explicit(explicitID)
  } else {
    element.key = .structural(parent: parent, kind: element.kind.identityName, index: index)
  }
  let childParent = element.key
  for childIndex in element.children.indices {
    assignKeys(&element.children[childIndex], parent: childParent, index: childIndex)
  }
}

/// Resolves inherited `.foregroundColor` and `.disabled` values.
///
/// Foreground is inherited by every descendant; a value set on a descendant
/// wins. Disabled has the same shape, with `.disabled(false)` re-enabling a
/// subtree. This happens before diffing so the backend only sees effective
/// values.
func resolveEnvironment(
  _ element: inout Element,
  inheritedForeground: Color? = nil,
  inheritedDisabled: Bool = false
) {
  let foreground = element.props.foreground ?? inheritedForeground
  let disabled = element.props.disabledOverride ?? inheritedDisabled

  element.props.foreground = foreground
  element.props.enabled = !disabled

  for index in element.children.indices {
    resolveEnvironment(
      &element.children[index],
      inheritedForeground: foreground,
      inheritedDisabled: disabled
    )
  }
}

/// Collects the current tap handlers keyed by node id.
func collectActions(_ element: Element, into actions: inout [NodeID: () -> Void]) {
  if let action = element.action {
    actions[element.id] = action
  }
  for child in element.children {
    collectActions(child, into: &actions)
  }
}
