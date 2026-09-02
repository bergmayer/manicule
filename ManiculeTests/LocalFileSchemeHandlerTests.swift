import XCTest
@testable import Manicule

final class LocalFileSchemeHandlerTests: XCTestCase {
    func testRejectsBundleTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(LocalFileSchemeHandler.resolvedFile(
            relativePath: "../../../../etc/passwd", under: root))
        XCTAssertNil(LocalFileSchemeHandler.resolvedFile(
            relativePath: "foliate-js/../reader.html", under: root))
    }

    func testRejectsPercentEncodedTraversalFromURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try XCTUnwrap(URL(string: "epub-local://bundle/%2e%2e/%2e%2e/etc/passwd"))
        XCTAssertNil(LocalFileSchemeHandler.resolvedFile(
            relativePath: String(url.path.dropFirst()), under: root))
    }

    func testRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        XCTAssertNil(LocalFileSchemeHandler.resolvedFile(
            relativePath: "escape/secret.txt", under: root))
    }

    func testAllowsOrdinaryContainedResource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = LocalFileSchemeHandler.resolvedFile(
            relativePath: "images/cover.jpg", under: root)
        XCTAssertEqual(resolved?.path, root.appendingPathComponent("images/cover.jpg").path)
    }

    func testMIMETypeLookupHandlesAliasesAndUnknownExtensions() {
        XCTAssertEqual(LocalFileSchemeHandler.mimeType(for: "HTML"), "text/html")
        XCTAssertEqual(LocalFileSchemeHandler.mimeType(for: "jpeg"), "image/jpeg")
        XCTAssertEqual(LocalFileSchemeHandler.mimeType(for: "unknown"), "application/octet-stream")
    }
}

final class MarkdownHTMLRendererTests: XCTestCase {
    func testRendersBlocksInlineMarkupAndHeadingAnchors() {
        let markdown = """
        # Heading

        A **bold** paragraph with `literal *code*`.

        - First
        - Second
        """

        let html = MarkdownHTMLRenderer.render(markdown, headingAnchorPrefix: "toc-")

        XCTAssertTrue(html.contains("<h1 id=\"toc-0\">Heading</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>literal *code*</code>"))
        XCTAssertTrue(html.contains("<ul><li>First</li><li>Second</li></ul>"))
    }

    func testRendersTableAndEscapesUnsafeText() {
        let markdown = """
        | Name | Value |
        | --- | ---: |
        | A&B | <unsafe> |
        """

        let html = MarkdownHTMLRenderer.render(markdown)

        XCTAssertTrue(html.contains("<thead><tr><th>Name</th><th>Value</th></tr></thead>"))
        XCTAssertTrue(html.contains("<td>A&amp;B</td>"))
        XCTAssertTrue(html.contains("<td>&lt;unsafe&gt;</td>"))
    }
}

final class ReaderThemeTests: XCTestCase {
    func testIncludesPilcrowColorThemes() {
        let expected = [
            "Solarized Light", "Solarized Dark", "Dracula", "Nord", "Platinum",
            "Norton", "Amber CRT", "Phosphor Green", "Black and White",
        ]
        XCTAssertTrue(expected.allSatisfy { name in
            ReaderTheme.allCases.contains { $0.rawValue == name }
        })
    }

    func testPortedThemeColorsMatchPilcrowPalettes() {
        XCTAssertEqual(ReaderTheme.solarizedDark.cssBackground, "#002b36")
        XCTAssertEqual(ReaderTheme.dracula.cssForeground, "#f8f8f2")
        XCTAssertEqual(ReaderTheme.nord.cssAccent, "#88c0d0")
        XCTAssertEqual(ReaderTheme.amber.cssForeground, "#ffb000")
        XCTAssertEqual(ReaderTheme.phosphorGreen.cssBackground, "#000c00")
    }
}
