import WebKit
import XCTest
@testable import rædað

@MainActor
final class EPubWebViewIntegrationTests: XCTestCase {
    func testEPubRendersReadableTextInWebKit() async throws {
        let text = try await renderedText(lastLocation: nil)
        XCTAssertTrue(text.contains("Hello, World!"),
                      "Rendered EPUB text was: \(text)")
    }

    func testInvalidSavedLocationFallsBackToReadableText() async throws {
        // This is structurally a CFI, but points outside the book's spine.
        // Foliate used to accept it without loading a section, leaving a blank
        // reader on every subsequent open of that book.
        let text = try await renderedText(lastLocation: "epubcfi(/6/999)")
        XCTAssertTrue(text.contains("Hello, World!"),
                      "Fallback EPUB text was: \(text)")
    }

    private func renderedText(lastLocation: String?) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-webkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bookURL = directory.appendingPathComponent("book.epub")
        try DocumentContentTests.minimalEPub().write(to: bookURL, options: .atomic)

        let schemeHandler = LocalFileSchemeHandler(baseURL: directory)
        schemeHandler.bundleResourceURL = try XCTUnwrap(Bundle.main.resourceURL)
        schemeHandler.bookFileURL = bookURL

        let coordinator = WebViewCoordinator()
        coordinator.isEPub = true
        coordinator.schemeHandler = schemeHandler

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "epub-local")
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: "pageHandler")
        contentController.add(coordinator, name: "bridge")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700),
                                configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        let bridgeReady = expectation(description: "EPUB bridge became ready")
        let readableText = expectation(description: "EPUB produced readable section text")
        var capturedText = ""
        var requestedText = false

        coordinator.onBridgeReady = {
            bridgeReady.fulfill()
            coordinator.bridgeOpenAndInit(
                flow: "paginated",
                css: "",
                oneTB: 24,
                oneLR: 24,
                twoTB: 24,
                twoLR: 24,
                maxColumnCount: 1,
                lastLocation: lastLocation
            )
        }
        coordinator.onRelocate = { _ in
            guard !requestedText else { return }
            requestedText = true
            coordinator.bridgeStartReadAloud()
        }
        coordinator.onReadAloudSectionText = { text, _, _ in
            capturedText = text
            readableText.fulfill()
        }

        let readerURL = try XCTUnwrap(URL(string: "epub-local://bundle/reader.html"))
        coordinator.currentFileURL = readerURL
        webView.load(URLRequest(url: readerURL))

        await fulfillment(of: [bridgeReady, readableText], timeout: 20)
        coordinator.tearDown()
        return capturedText
    }
}
