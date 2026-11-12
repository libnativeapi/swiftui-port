/// A color in the engine's platform-independent representation.
///
/// The native backend converts this to `NativeAPI.Color`; keeping a separate
/// type is what lets `SwiftUIRuntime` stay free of nativeapi imports. Color
/// components are 0...1; values outside the range are clamped when converted.
public struct Color: Hashable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var opacity: Double

  public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  /// A gray color with the given brightness (0 = black, 1 = white).
  public init(white: Double, opacity: Double = 1) {
    self.init(red: white, green: white, blue: white, opacity: opacity)
  }

  /// A color from a 0xRRGGBB literal.
  public init(hex: UInt32, opacity: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255.0,
      green: Double((hex >> 8) & 0xFF) / 255.0,
      blue: Double(hex & 0xFF) / 255.0,
      opacity: opacity
    )
  }

  public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
  public static let black = Color(red: 0, green: 0, blue: 0)
  public static let white = Color(red: 1, green: 1, blue: 1)
  public static let red = Color(red: 1, green: 0, blue: 0)
  public static let green = Color(red: 0, green: 1, blue: 0)
  public static let blue = Color(red: 0, green: 0, blue: 1)
  public static let yellow = Color(red: 1, green: 1, blue: 0)
  public static let orange = Color(red: 1, green: 0.5, blue: 0)
  public static let purple = Color(red: 0.5, green: 0, blue: 0.5)
  public static let gray = Color(white: 0.5)
  public static let secondary = Color(white: 0.35)
}
