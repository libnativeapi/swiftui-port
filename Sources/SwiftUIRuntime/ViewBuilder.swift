/// Builds a ``View`` from a closure with 0–10 child expressions, plus
/// conditionals and loops.
///
/// The implementation follows the result-builder shape SwiftUI uses, so the
/// same `if` / `switch` / `for` forms compile. A block with several children
/// becomes a ``TupleView`` fragment; containers flatten fragments when they
/// collect their children.

/// A fragment of zero or more elements, produced by a multi-expression builder
/// block. Containers flatten it before laying out their children.

/// The zero-or-one element fragment produced by an `if` without an `else`.

/// The selected branch of a `switch` or `if`/`else` in a builder block.

/// The fragment produced by a `for` loop in a builder block.

@resultBuilder
@MainActor @preconcurrency
public enum ViewBuilder {
  public static func buildExpression<V: View>(_ expression: V) -> V {
    expression
  }

  public static func buildBlock() -> EmptyView {
    EmptyView()
  }

  public static func buildBlock<C: View>(_ content: C) -> C {
    content
  }

  public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
      ]
    }
  }

  public static func buildBlock<C0: View, C1: View, C2: View>(
    _ c0: C0, _ c1: C1, _ c2: C2
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
      ]
    }
  }

  public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
      ]
    }
  }

  public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
      ]
    }
  }

  public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View>(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
        _render(c5, path: path + [5]),
      ]
    }
  }

  public static func buildBlock<
    C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View
  >(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
        _render(c5, path: path + [5]),
        _render(c6, path: path + [6]),
      ]
    }
  }

  public static func buildBlock<
    C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View
  >(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
        _render(c5, path: path + [5]),
        _render(c6, path: path + [6]),
        _render(c7, path: path + [7]),
      ]
    }
  }

  public static func buildBlock<
    C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View
  >(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
        _render(c5, path: path + [5]),
        _render(c6, path: path + [6]),
        _render(c7, path: path + [7]),
        _render(c8, path: path + [8]),
      ]
    }
  }

  public static func buildBlock<
    C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View,
    C9: View
  >(
    _ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8,
    _ c9: C9
  ) -> TupleView {
    TupleView { path in
      [
        _render(c0, path: path + [0]),
        _render(c1, path: path + [1]),
        _render(c2, path: path + [2]),
        _render(c3, path: path + [3]),
        _render(c4, path: path + [4]),
        _render(c5, path: path + [5]),
        _render(c6, path: path + [6]),
        _render(c7, path: path + [7]),
        _render(c8, path: path + [8]),
        _render(c9, path: path + [9]),
      ]
    }
  }

  public static func buildOptional<C: View>(_ component: C?) -> OptionalView<C> {
    OptionalView(component)
  }

  public static func buildEither<T: View, F: View>(first component: T) -> _ConditionalContent<T, F>
  {
    .first(component)
  }

  public static func buildEither<T: View, F: View>(second component: F) -> _ConditionalContent<T, F>
  {
    .second(component)
  }

  public static func buildArray<C: View>(_ components: [C]) -> ArrayView<C> {
    ArrayView(components)
  }
}
public struct TupleView: View {
  public typealias Body = Never

  private let builder: @MainActor ([Int]) -> [Element]

  init(_ builder: @escaping @MainActor ([Int]) -> [Element]) {
    self.builder = builder
  }

  public var body: Never { fatalError("TupleView is a fragment") }
}
extension TupleView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    Element(kind: .fragment, children: builder(path))
  }
}
public struct OptionalView<Content: View>: View {
  public typealias Body = Never

  private let content: Content?

  init(_ content: Content?) {
    self.content = content
  }

  public var body: Never { fatalError("OptionalView is a fragment") }
}
extension OptionalView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    guard let content else {
      return Element(kind: .fragment, children: [])
    }
    return Element(kind: .fragment, children: [_render(content, path: path)])
  }
}
public enum _ConditionalContent<TrueContent: View, FalseContent: View>: View {
  case first(TrueContent)
  case second(FalseContent)

  public typealias Body = Never

  public var body: Never { fatalError("_ConditionalContent is a fragment") }
}
extension _ConditionalContent: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    switch self {
    case .first(let content):
      return Element(kind: .fragment, children: [_render(content, path: path)])
    case .second(let content):
      return Element(kind: .fragment, children: [_render(content, path: path)])
    }
  }
}
public struct ArrayView<Content: View>: View {
  public typealias Body = Never

  private let content: [Content]

  init(_ content: [Content]) {
    self.content = content
  }

  public var body: Never { fatalError("ArrayView is a fragment") }
}
extension ArrayView: _PrimitiveView {
  func _makeElement(path: [Int]) -> Element {
    Element(
      kind: .fragment,
      children: content.enumerated().map { index, child in
        _render(child, path: path + [index])
      }
    )
  }
}
