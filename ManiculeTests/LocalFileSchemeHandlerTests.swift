import XCTest
@testable import Manicule

final class LocalFileSchemeHandlerTests: XCTestCase {
    @MainActor
    func testGeneratedPublicationRouteCannotEscapeItsLease() throws {
        let lease = try TemporaryDirectoryLease.create(prefix: "text-routing")
        let manifest = lease.url.appendingPathComponent("publication.json")
        let roots = LocalFileSchemeHandler.Roots(base: lease.url, document: nil,
            bundle: Bundle.main.resourceURL, book: manifest, lease: lease)
        XCTAssertEqual(try roots.resolve(URL(string: "epub-local://bundle/publication.json")!), manifest)
        XCTAssertEqual(try roots.resolve(URL(string: "epub-local://bundle/text/content.html")!),
                       lease.url.appendingPathComponent("content.html"))
        XCTAssertThrowsError(try roots.resolve(URL(string: "epub-local://bundle/text/../../outside.html")!))
    }

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

import WebKit

@MainActor
final class SchemeRequestLifecycleTests: XCTestCase {
    private final class Request: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: URLResponse?
        var bytes = Data()
        var error: Error?
        let completion: XCTestExpectation

        init(url: URL, completion: XCTestExpectation) {
            request = URLRequest(url: url)
            self.completion = completion
        }
        func didReceive(_ response: URLResponse) { self.response = response }
        func didReceive(_ data: Data) { bytes.append(data) }
        func didFinish() { completion.fulfill() }
        func didFailWithError(_ error: any Error) { self.error = error; completion.fulfill() }
    }

    func testLocalFetchPreservesHTTPStatusCharsetAndBytes() async throws {
        let directory = try TemporaryDirectoryLease.writing(Data("Café 👋".utf8), filename: "content.html")
        let handler = LocalFileSchemeHandler(baseURL: directory.url)
        handler.resourceLease = directory
        let done = expectation(description: "Local resource finished")
        var components = URLComponents()
        components.scheme = "epub-local"
        components.host = "local"
        components.path = directory.url.appendingPathComponent("content.html").path
        let request = Request(url: try XCTUnwrap(components.url), completion: done)
        handler.webView(WKWebView(), start: request)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNil(request.error)
        XCTAssertEqual((request.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(request.response?.textEncodingName, "utf-8")
        XCTAssertEqual(request.bytes, Data("Café 👋".utf8))
    }

    func testStoppedRequestDoesNotCallWebKitAgain() async throws {
        let directory = try TemporaryDirectoryLease.writing(Data("resource".utf8), filename: "content.html")
        let handler = LocalFileSchemeHandler(baseURL: directory.url)
        let completed = expectation(description: "Stopped request must not complete")
        completed.isInverted = true
        let request = Request(url: URL(string: "epub-local://document/content.html")!, completion: completed)
        handler.documentResourceURL = directory.url
        let webView = WKWebView()
        handler.webView(webView, start: request)
        handler.webView(webView, stop: request)
        await fulfillment(of: [completed], timeout: 0.2)
        XCTAssertNil(request.response)
        XCTAssertTrue(request.bytes.isEmpty)
    }

    func testRendererTerminationIsReportedOnceWithoutAutomaticReload() {
        let coordinator = WebViewCoordinator()
        let webView = WKWebView()
        var failures: [String] = []
        coordinator.onFailure = { failures.append($0) }
        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(webView.isLoading)
        coordinator.tearDown()
    }
}
