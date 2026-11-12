import Foundation

/// A point in a view's coordinate space.
///
/// The origin is the top-left corner of the containing view, matching
/// nativeapi's view geometry.
public struct Point: Equatable {
  public var x: Double
  public var y: Double

  public init(x: Double = 0, y: Double = 0) {
    self.x = x
    self.y = y
  }

  public static let zero = Point()
}

/// A width/height pair in logical points.
public struct Size: Equatable {
  public var width: Double
  public var height: Double

  public init(width: Double = 0, height: Double = 0) {
    self.width = width
    self.height = height
  }

  public static let zero = Size()

  public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// An axis-aligned rectangle in the parent's coordinate space.
public struct Rect: Equatable {
  public var origin: Point
  public var size: Size

  public init(origin: Point = .zero, size: Size = .zero) {
    self.origin = origin
    self.size = size
  }

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.origin = Point(x: x, y: y)
    self.size = Size(width: width, height: height)
  }

  public static let zero = Rect()

  public var minX: Double { origin.x }
  public var minY: Double { origin.y }
  public var maxX: Double { origin.x + size.width }
  public var maxY: Double { origin.y + size.height }
  public var width: Double { size.width }
  public var height: Double { size.height }

  public func inset(by insets: EdgeInsets) -> Rect {
    Rect(
      x: minX + insets.leading,
      y: minY + insets.top,
      width: max(0, size.width - insets.leading - insets.trailing),
      height: max(0, size.height - insets.top - insets.bottom)
    )
  }
}

/// Per-edge padding values in logical points.
public struct EdgeInsets: Equatable {
  public var top: Double
  public var leading: Double
  public var bottom: Double
  public var trailing: Double

  public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
    self.top = top
    self.leading = leading
    self.bottom = bottom
    self.trailing = trailing
  }

  public static let zero = EdgeInsets()

  public static func all(_ value: Double) -> EdgeInsets {
    EdgeInsets(top: value, leading: value, bottom: value, trailing: value)
  }

  public static func symmetric(vertical: Double, horizontal: Double) -> EdgeInsets {
    EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
  }

  public var horizontal: Double { leading + trailing }
  public var vertical: Double { top + bottom }

  public static func + (lhs: EdgeInsets, rhs: EdgeInsets) -> EdgeInsets {
    EdgeInsets(
      top: lhs.top + rhs.top,
      leading: lhs.leading + rhs.leading,
      bottom: lhs.bottom + rhs.bottom,
      trailing: lhs.trailing + rhs.trailing
    )
  }
}

/// A horizontal alignment inside a vertical stack, and the horizontal
/// component of ``Alignment``.
public enum HorizontalAlignment: Equatable {
  case leading
  case center
  case trailing
}

/// A vertical alignment inside a horizontal stack, and the vertical component
/// of ``Alignment``.
public enum VerticalAlignment: Equatable {
  case top
  case center
  case bottom
}

/// A two-axis alignment, used by ``View/frame(width:height:alignment:)``.
public struct Alignment: Equatable {
  public var horizontal: HorizontalAlignment
  public var vertical: VerticalAlignment

  public init(horizontal: HorizontalAlignment = .center, vertical: VerticalAlignment = .center) {
    self.horizontal = horizontal
    self.vertical = vertical
  }

  public static let center = Alignment()
  public static let leading = Alignment(horizontal: .leading)
  public static let trailing = Alignment(horizontal: .trailing)
  public static let top = Alignment(vertical: .top)
  public static let bottom = Alignment(vertical: .bottom)
  public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
  public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
  public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
  public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

/// Which axis a stack lays its children out on.
public enum Axis: Equatable {
  case horizontal
  case vertical
}
