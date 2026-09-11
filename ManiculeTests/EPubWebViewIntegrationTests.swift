import WebKit
import XCTest
@testable import Manicule

@MainActor
final class EPubWebViewIntegrationTests: XCTestCase {
    func testPaginatedTextBecomesVisibleAndReportsPages() async throws {
        let html = """
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'"></head>
        <body><h1>Visible reader</h1>\(String(repeating: "<p>Café 👋 readable text.</p>", count: 80))</body></html>
        """
        let directory = try TemporaryDirectoryLease.writing(Data(html.utf8), filename: "content.html")
        let handler = LocalFileSchemeHandler(baseURL: directory.url)
        let coordinator = WebViewCoordinator()
        coordinator.schemeHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "epub-local")
        configuration.userContentController.add(coordinator, name: "pageHandler")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.style.setProperty('visibility', 'hidden', 'important');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        // Pagination waits for animation frames. An unattached WebView is
        // throttled by WebKit and cannot exercise the visible-reader lifecycle.
        let closeWindow = try showInWindow(webView)
        defer { closeWindow() }
        defer { coordinator.tearDown() }
        let pagesReported = expectation(description: "Text reader paginated")
        pagesReported.assertForOverFulfill = false
        let content = WebViewContent(
            fileURL: directory.url.appendingPathComponent("content.html"), baseURL: directory.url,
            scrollFraction: nil, fragment: nil, cssOverride: nil, paginated: true)
        WebViewRepresentable(content: content, onPageInfo: { _, total in
            XCTAssertGreaterThan(total, 1)
            pagesReported.fulfill()
        }).update(webView, coordinator: coordinator, refocus: {})
        await fulfillment(of: [pagesReported], timeout: 10)
        // Page counts can arrive during preliminary layout. Wait for the
        // observable visible state, not merely the first pagination message.
        let visibility = try await webView.callAsyncJavaScript("""
            return new Promise(resolve => {
                const deadline = performance.now() + 8000;
                function check() {
                    const value = getComputedStyle(document.documentElement).visibility;
                    if (value === 'visible' || performance.now() > deadline) resolve(value);
                    else requestAnimationFrame(check);
                }
                check();
            });
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(visibility, "visible")
    }

    func testSharedUpdateRendersReplacementTextAndRefreshesResourceRoot() async throws {
        let first = try TemporaryDirectoryLease.writing(
            Data("<html><body>First snapshot</body></html>".utf8), filename: "content.html")
        let second = try TemporaryDirectoryLease.writing(
            Data("<html><body>Second snapshot 👋</body></html>".utf8), filename: "content.html")
        let handler = LocalFileSchemeHandler(baseURL: first.url)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "epub-local")
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let coordinator = WebViewCoordinator()
        coordinator.webView = webView
        coordinator.schemeHandler = handler
        webView.navigationDelegate = coordinator
        defer { coordinator.tearDown() }

        for (directory, expected) in [(first, "First snapshot"), (second, "Second snapshot 👋")] {
            let loaded = expectation(description: "Loaded \(expected)")
            let observation = webView.observe(\.isLoading, options: .new) { view, _ in
                MainActor.assumeIsolated {
                    if !view.isLoading { loaded.fulfill() }
                }
            }
            let content = WebViewContent(
                fileURL: directory.url.appendingPathComponent("content.html"),
                baseURL: directory.url, scrollFraction: nil, fragment: nil,
                cssOverride: nil, paginated: false, resourceBaseURL: directory.url)
            WebViewRepresentable(content: content).update(webView, coordinator: coordinator, refocus: {})
            await fulfillment(of: [loaded], timeout: 10)
            observation.invalidate()
            let text = try await webView.evaluateJavaScript("document.body.textContent") as? String
            XCTAssertEqual(text, expected)
            XCTAssertEqual(handler.baseURL, directory.url)
            XCTAssertEqual(handler.documentResourceURL, directory.url)
        }
    }

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

    func testTextPassageRestoresAcrossMarkdownModesAndFontSizes() async throws {
        let source = (0..<60).map { index in
            "## Chapter \(index)\n\nUnique passage \(index) Café 👋 " + String(repeating: "readable text ", count: 70)
        }.joined(separator: "\n\n")
        // Each chapter occupies four source lines. The same passage must be
        // visible even though Markdown syntax and page counts change.
        let anchor = TextAnchor(line: 37 * 4 + 2, quote: "Unique passage 37 Café 👋")
        for (markdown, size, paginated) in [(true, 18, true), (false, 30, true), (true, 26, false)] {
            let prepared = try TextPreparation.prepare(source, reflow: false, markdown: markdown, hasFile: false)
            let handler = LocalFileSchemeHandler(baseURL: prepared.directory.url)
            let coordinator = WebViewCoordinator()
            coordinator.schemeHandler = handler
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(handler, forURLScheme: "epub-local")
            config.userContentController.add(coordinator, name: "pageHandler")
            config.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.style.setProperty('visibility', 'hidden', 'important');",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let webView = WKWebView(frame: .init(x: 0, y: 0, width: 650, height: 600), configuration: config)
            coordinator.webView = webView
            webView.navigationDelegate = coordinator
            let closeWindow = try showInWindow(webView)
            defer { closeWindow(); coordinator.tearDown() }
            let ready = expectation(description: "Source position restored")
            ready.assertForOverFulfill = false
            let content = WebViewContent(
                fileURL: prepared.directory.url.appendingPathComponent("content.html"), baseURL: prepared.directory.url,
                scrollFraction: 0, fragment: nil, cssOverride: "body { font-size: \(size)px !important; }", paginated: paginated,
                twoUp: false, resourceLease: prepared.directory, textAnchor: anchor)
            WebViewRepresentable(content: content, onScrollPositionChange: { _ in ready.fulfill() })
                .update(webView, coordinator: coordinator, refocus: {})
            await fulfillment(of: [ready], timeout: 20)
            _ = try await webView.callAsyncJavaScript("""
                return new Promise(resolve => {
                    const deadline = performance.now() + 8000;
                    function check() {
                        if (getComputedStyle(document.documentElement).visibility === 'visible' || performance.now() > deadline) resolve(true);
                        else requestAnimationFrame(check);
                    }
                    check();
                });
                """, arguments: [:], in: nil, contentWorld: .page)
            // Test visible text geometry, not just its presence in the DOM.
            let visibility = try await webView.evaluateJavaScript("""
                (() => {
                    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                    let node;
                    while ((node = walker.nextNode())) {
                        const offset = node.textContent.indexOf('Unique passage 37 Café 👋');
                        if (offset < 0) continue;
                        const range = document.createRange();
                        range.setStart(node, offset); range.setEnd(node, offset + 8);
                        const rects = Array.from(range.getClientRects());
                        return {visible: rects.some(r => r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight),
                            rects: rects.map(r => ({x:r.x, y:r.y, width:r.width, height:r.height})),
                            scrollY: scrollY, viewport: [innerWidth, innerHeight]};
                    }
                    return false;
                })();
                """) as? [String: Any]
            XCTAssertEqual(visibility?["visible"] as? Bool, true, "markdown=\(markdown), font=\(size), paginated=\(paginated), geometry=\(String(describing: visibility))")
            let captured = try await webView.evaluateJavaScript("window.manicule.captureTextAnchor()")
            XCTAssertNotNil(captured, "A displayed source passage must produce a persistable anchor")
        }
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

        let closeWindow = try showInWindow(webView)
        defer { closeWindow(); coordinator.tearDown() }

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
        return capturedText
    }

    /// WebKit may suspend detached views before layout/relocation finishes.
    /// Retain a visible host until each observable rendering assertion completes.
    private func showInWindow(_ webView: WKWebView) throws -> () -> Void {
        #if os(macOS)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        return { window.orderOut(nil) }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return { window.isHidden = true }
        #endif
    }
}
