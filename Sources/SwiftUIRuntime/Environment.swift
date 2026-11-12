/// The inherited values the engine resolves before diffing.
///
/// v0.1 does not expose `@Environment`; the engine uses this shape internally
/// for `.foregroundColor` and `.disabled`. A future version can grow a public
/// key/value environment without changing the element tree.
public struct EnvironmentValues: Equatable {
  public var foregroundColor: Color?
  public var isEnabled: Bool

  public init(foregroundColor: Color? = nil, isEnabled: Bool = true) {
    self.foregroundColor = foregroundColor
    self.isEnabled = isEnabled
  }

  public static let `default` = EnvironmentValues()
}
