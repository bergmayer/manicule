import XCTest
@testable import rædað

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
}
