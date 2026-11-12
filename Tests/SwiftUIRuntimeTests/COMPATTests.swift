import Foundation
import XCTest

/// Keeps docs/COMPAT.md honest: every row marked supported/partial must name a
/// symbol that exists in Sources, and the v0.1 must-have list must be present.
final class COMPATTests: XCTestCase {
  private struct Row {
    let symbol: String
    let status: String
    let line: Int
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func compatRows() throws -> [Row] {
    let url = repositoryRoot.appendingPathComponent("docs/COMPAT.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    var rows: [Row] = []

    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("|") else { continue }
      let cells = trimmed
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard cells.count >= 3 else { continue }
      let symbolCell = cells[1]
      let status = cells[2]
      guard status == "supported" || status == "partial" || status == "missing" else { continue }
      guard let symbol = firstBacktickedSymbol(in: symbolCell) else { continue }
      rows.append(Row(symbol: symbol, status: status, line: index + 1))
    }
    return rows
  }

  private func firstBacktickedSymbol(in cell: String) -> String? {
    guard let start = cell.firstIndex(of: "`"),
          let end = cell[cell.index(after: start)...].firstIndex(of: "`")
    else { return nil }
    return String(cell[cell.index(after: start)..<end])
  }

  /// Reduces a documentation spelling such as `@ViewBuilder`,
  /// `VStack(alignment:spacing:)` or `.padding(_:)` to an identifier that can
  /// be searched for in the source.
  private func normalizedIdentifier(_ symbol: String) -> String {
    var name = symbol
    if name.hasPrefix("@") { name.removeFirst() }
    if name.hasPrefix(".") { name.removeFirst() }
    if let paren = name.firstIndex(of: "(") {
      name = String(name[..<paren])
    }
    if let dot = name.lastIndex(of: ".") {
      name = String(name[name.index(after: dot)...])
    }
    return name
  }

  private func sourceText() throws -> String {
    let sources = repositoryRoot.appendingPathComponent("Sources")
    guard let enumerator = FileManager.default.enumerator(
      at: sources,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return ""
    }

    var text = ""
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      text += "\n"
    }
    return text
  }

  func testEverySupportedSymbolExistsInSources() throws {
    let sources = try sourceText()
    XCTAssertFalse(sources.isEmpty, "no Swift sources found")

    for row in try compatRows() where row.status == "supported" || row.status == "partial" {
      let identifier = normalizedIdentifier(row.symbol)
      guard !identifier.isEmpty, !identifier.contains(" ") else { continue }

      // The facade's name is the target name, not an identifier in a file.
      if identifier == "SwiftUI" {
        let facade = repositoryRoot.appendingPathComponent("Sources/SwiftUI/SwiftUI.swift")
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: facade.path),
          "docs/COMPAT.md:\(row.line): \(row.symbol) is marked \(row.status) but Sources/SwiftUI is missing"
        )
        continue
      }

      let pattern = "\\b\(NSRegularExpression.escapedPattern(for: identifier))\\b"
      let regex = try NSRegularExpression(pattern: pattern)
      let range = NSRange(location: 0, length: sources.utf16.count)
      let matches = regex.numberOfMatches(in: sources, range: range)
      XCTAssertGreaterThan(
        matches,
        0,
        "docs/COMPAT.md:\(row.line): \(row.symbol) is marked \(row.status) but '\(identifier)' is not in Sources"
      )
    }
  }

  func testMustHaveSymbolsAreDocumented() throws {
    let mustHave = [
      "View", "body", "ViewBuilder", "EmptyView", "AnyView",
      "VStack", "HStack", "Spacer", "Text", "Button",
      "State", "Binding",
      "padding", "frame", "background", "foregroundColor", "hidden",
      "disabled", "onTapGesture", "id",
      "App", "Scene", "WindowGroup", "main",
    ]

    let documented = Set(
      try compatRows()
        .filter { $0.status == "supported" || $0.status == "partial" }
        .map { normalizedIdentifier($0.symbol) }
    )

    for symbol in mustHave {
      XCTAssertTrue(
        documented.contains(symbol),
        "v0.1 symbol '\(symbol)' has no supported/partial row in docs/COMPAT.md"
      )
    }
  }
}
