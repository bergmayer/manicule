import WebKit
import XCTest
@testable import Manicule

/// Exercises actual Foliate frames through the native scheme handler, rather
/// than a second test implementation of text layout.
@MainActor
final class EPubWebViewIntegrationTests: XCTestCase {
    @MainActor
    private struct Reader {
        let view: WKWebView
        let coordinator: WebViewCoordinator
        let closeWindow: () -> Void
        let location: RelocateEvent
        func close() { coordinator.tearDown(); closeWindow() }
    }

    private func open(_ file: URL, lease: TemporaryDirectoryLease,
                      anchor: TextAnchor? = nil, fraction: Double? = nil,
                      flow: String = "paginated", columns: Int = 1,
                      css: String = "body { font-size: 20px; line-height: 1.4; }",
                      lastLocation: String? = nil) async throws -> Reader {
        let handler = LocalFileSchemeHandler(baseURL: lease.url)
        handler.bundleResourceURL = Bundle.main.resourceURL
        let coordinator = WebViewCoordinator()
        coordinator.schemeHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "epub-local")
        configuration.userContentController.add(coordinator, name: "bridge")
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        coordinator.webView = view
        view.navigationDelegate = coordinator
        let close = try showInWindow(view)
        let ready = expectation(description: "Foliate rendered publication")
        ready.assertForOverFulfill = false
        var location: RelocateEvent?
        let content = WebViewContent(baseURL: lease.url, bookFileURL: file,
            resourceLease: lease, scrollFraction: fraction, textAnchor: anchor)
        WebViewRepresentable(content: content, onRelocate: { event in
            location = event
            ready.fulfill()
        }, onBridgeReady: {
            coordinator.bridgeOpenAndInit(flow: flow, css: css, oneTB: 24, oneLR: 24,
                twoTB: 40, twoLR: 40, maxColumnCount: columns, lastLocation: lastLocation)
        }, onFailure: { message in
            XCTFail(message)
            ready.fulfill()
        }).update(view, coordinator: coordinator, refocus: {})
        await fulfillment(of: [ready], timeout: 30)
        guard let location else { coordinator.tearDown(); close(); throw CocoaError(.fileReadCorruptFile) }
        return Reader(view: view, coordinator: coordinator, closeWindow: close, location: location)
    }

    private func text(_ source: String, markdown: Bool = false) throws -> TextPreparation.Prepared {
        try TextPreparation.prepare(source, reflow: false, markdown: markdown, hasFile: false, markdownSource: markdown)
    }
    private func open(_ prepared: TextPreparation.Prepared, anchor: TextAnchor? = nil,
                      fraction: Double? = nil, flow: String = "paginated", columns: Int = 1) async throws -> Reader {
        try await open(prepared.directory.url.appendingPathComponent("publication.json"), lease: prepared.directory,
                       anchor: anchor, fraction: fraction, flow: flow, columns: columns)
    }
    private let document = "document.querySelector('foliate-view').renderer.getContents()[0].doc"

    func testPlainTextUsesFoliatePaginationAndSharedDisplayOptions() async throws {
        let prepared = try text(String(repeating: "Café 👋 readable text. ", count: 2000))
        let reader = try await open(prepared)
        defer { reader.close() }
        XCTAssertGreaterThan(reader.location.pages ?? 0, 1)
        let metrics = try await reader.view.evaluateJavaScript("""
            (() => { const doc = \(document); const style = doc.defaultView.getComputedStyle(doc.body);
            return { text: doc.body.textContent, size: style.fontSize, height: style.lineHeight }; })()
            """) as? [String: Any]
        XCTAssertTrue((metrics?["text"] as? String)?.contains("Café 👋") == true)
        XCTAssertEqual(metrics?["size"] as? String, "20px")
        let changed = try await reader.view.callAsyncJavaScript("""
            window.bridge.setStyles('body, p, span { font-size: 26px !important; line-height: 1.8 !important; text-align: justify !important; }');
            window.bridge.setMarginsBoth(36, 36, 60, 60);
            window.bridge.setColumnCount(2);
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const v = document.querySelector('foliate-view');
            const doc = v.renderer.getContents()[0].doc;
            const style = doc.defaultView.getComputedStyle(doc.querySelector('p'));
            return { size: style.fontSize, align: style.textAlign, columns: v.renderer.getAttribute('max-column-count'), margin: v.renderer.getAttribute('margin') };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(changed?["size"] as? String, "26px")
        XCTAssertEqual(changed?["align"] as? String, "justify")
        XCTAssertEqual(changed?["columns"] as? String, "2")
        XCTAssertEqual(changed?["margin"] as? String, "60px")
    }

    func testSharedTypographyPreservesHeadingsAndThemes() async throws {
        let prepared = try text("# Heading\n\nA **bold** paragraph.", markdown: true)
        let preferences = EffectivePreferences(fontFamily: .georgia, fontSize: 22, lineSpacing: 1.6,
            marginsOneUp: .init(topBottom: 24, leftRight: 24), marginsTwoUp: .init(topBottom: 40, leftRight: 40),
            theme: .sepia, viewMode: .paginated, twoUp: false, reflowText: false, trimWhitespace: false, textAlign: .justified)
        let reader = try await open(prepared.directory.url.appendingPathComponent("publication.json"),
            lease: prepared.directory, css: preferences.foliateCSS)
        defer { reader.close() }
        let metrics = try await reader.view.evaluateJavaScript("""
            (() => { const doc = \(document); const style = e => doc.defaultView.getComputedStyle(e);
            return { paragraph: parseFloat(style(doc.querySelector('p')).fontSize),
                heading: parseFloat(style(doc.querySelector('h1')).fontSize),
                align: style(doc.querySelector('p')).textAlign,
                background: style(doc.body).backgroundColor }; })()
            """) as? [String: Any]
        XCTAssertEqual(metrics?["paragraph"] as? Double, 22)
        XCTAssertGreaterThan(metrics?["heading"] as? Double ?? 0, 22)
        XCTAssertEqual(metrics?["align"] as? String, "justify")
        XCTAssertEqual(metrics?["background"] as? String, "rgb(245, 230, 200)")
    }

    func testTextPassageRestoresAcrossMarkdownModesAndSections() async throws {
        let source = (0..<100).map { index in
            "## Chapter \(index)\n\nUnique passage \(index) Café 👋 " + String(repeating: "readable text ", count: 70)
        }.joined(separator: "\n\n")
        let anchor = TextAnchor(line: 37 * 4 + 2, quote: "Unique passage 37 Café 👋")
        for (markdown, flow, columns) in [(false, "paginated", 1), (true, "paginated", 2), (false, "scrolled", 1), (true, "scrolled", 1)] {
            let prepared = try TextPreparation.prepare(source, reflow: false, markdown: markdown,
                hasFile: false, markdownSource: true)
            let reader = try await open(prepared, anchor: anchor, flow: flow, columns: columns)
            defer { reader.close() }
            XCTAssertNotNil(reader.location.textAnchor)
            let visible = try await reader.view.callAsyncJavaScript("""
                const measure = () => { const doc = \(document); const frame = doc.defaultView.frameElement.getBoundingClientRect();
                const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT); let node;
                while ((node = walker.nextNode())) {
                    const offset = node.textContent.indexOf('Unique passage 37 Café 👋');
                    if (offset < 0) continue;
                    const r = doc.createRange(); r.setStart(node, offset); r.setEnd(node, offset + 8);
                    const rects = Array.from(r.getClientRects());
                    return { visible: rects.some(r => r.right + frame.left > 0 && r.left + frame.left < innerWidth && r.bottom + frame.top > 0 && r.top + frame.top < innerHeight),
                        rects: rects.map(r => [r.x + frame.left, r.y + frame.top, r.width, r.height]), viewport: [innerWidth, innerHeight] };
                } return { visible: false }; };
                const deadline = performance.now() + 8000;
                return await new Promise(resolve => {
                    function check() {
                        const result = measure();
                        if (result.visible || performance.now() >= deadline) resolve(result);
                        else setTimeout(check, 20);
                    }
                    check();
                });
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(visible?["visible"] as? Bool, true, "markdown=\(markdown), flow=\(flow), columns=\(columns), geometry=\(String(describing: visible))")
        }
    }

    func testNewlineFreeTextRestoresUTF16OffsetAcrossSections() async throws {
        let prefix = String(repeating: "Café 👋 words ", count: 20_000)
        let source = prefix + "Target passage 日本語" + String(repeating: " more words", count: 10_000)
        let prepared = try text(source)
        let reader = try await open(prepared, anchor: TextAnchor(line: 0, offset: prefix.utf16.count, quote: "Target passage 日本語"))
        defer { reader.close() }
        XCTAssertGreaterThan(reader.location.sectionIndex ?? 0, 0)
        XCTAssertGreaterThan(reader.location.textAnchor?.offset ?? 0, 100_000)
        let body = try await reader.view.evaluateJavaScript("\(document).body.textContent") as? String
        XCTAssertTrue(body?.contains("Target passage 日本語") == true)
    }

    func testSourceAnchorRestoresAfterReflowAcrossSectionBoundaries() async throws {
        let source = (0..<2500).map { "Source line \($0) " + String(repeating: "flowing prose ", count: 8) }.joined(separator: "\n")
        let quote = "Source line 1737 "
        let prepared = try TextPreparation.prepare(source, reflow: true, markdown: false, hasFile: false)
        let reader = try await open(prepared, anchor: TextAnchor(line: 1737, quote: quote))
        defer { reader.close() }
        let body = try await reader.view.evaluateJavaScript("\(document).body.textContent") as? String
        XCTAssertTrue(body?.contains(quote) == true)
        XCTAssertNotNil(reader.location.textAnchor)
    }

    func testSearchAndNarrationUseDisplayedMarkdownText() async throws {
        let prepared = try text("# A heading\n\nA **distinctive** Café 👋 passage.", markdown: true)
        let reader = try await open(prepared)
        defer { reader.close() }
        let found = expectation(description: "Shared Foliate search found text")
        reader.coordinator.onSearchResult = { results, done in
            if done { XCTAssertFalse(results.isEmpty); found.fulfill() }
        }
        reader.coordinator.bridgeSearch("distinctive")
        await fulfillment(of: [found], timeout: 10)
        let spoken = expectation(description: "Shared narration extracted displayed text")
        reader.coordinator.onReadAloudSectionText = { text, _, _ in
            XCTAssertTrue(text.contains("distinctive")); XCTAssertFalse(text.contains("**")); spoken.fulfill()
        }
        reader.coordinator.bridgeStartReadAloud()
        await fulfillment(of: [spoken], timeout: 10)
    }

    func testMultiMegabyteTextLoadsOneSectionAndCanNavigateNearTheEnd() async throws {
        let source = (0..<20_000).map { "Paragraph \($0). " + String(repeating: "flowing words ", count: 10) }.joined(separator: "\n\n")
        XCTAssertGreaterThan(source.utf8.count, 2_500_000)
        let started = Date()
        let prepared = try text(source)
        let preparationTime = Date().timeIntervalSince(started)
        let reader = try await open(prepared)
        defer { reader.close() }
        let counts = try await reader.view.evaluateJavaScript("""
            (() => { const v = document.querySelector('foliate-view');
            return { sections: v.book.sections.length, loaded: v.renderer.getContents().length }; })()
            """) as? [String: Int]
        XCTAssertGreaterThan(counts?["sections"] ?? 0, 20)
        XCTAssertEqual(counts?["loaded"], 1)
        let relocated = expectation(description: "Navigated near end of large text")
        relocated.assertForOverFulfill = false
        reader.coordinator.onRelocate = { event in
            if (event.fraction ?? 0) > 0.85 { relocated.fulfill() }
        }
        reader.coordinator.bridgeGoToFraction(0.9)
        await fulfillment(of: [relocated], timeout: 20)
        print("Large-text validation: \(source.utf8.count) bytes, preparation \(preparationTime)s, initial load and end navigation \(Date().timeIntervalSince(started) - preparationTime)s")
    }

    func testLegacyFractionRestoresIntoLaterTextSection() async throws {
        let prepared = try text((0..<3000).map { "Paragraph \($0). " + String(repeating: "words ", count: 20) }.joined(separator: "\n\n"))
        let reader = try await open(prepared, fraction: 0.7)
        defer { reader.close() }
        XCTAssertGreaterThan(reader.location.sectionIndex ?? 0, 0)
        XCTAssertEqual(reader.location.fraction ?? 0, 0.7, accuracy: 0.05)
    }

    func testEmptyTextProducesReadableSection() async throws {
        let prepared = try text("")
        let reader = try await open(prepared)
        defer { reader.close() }
        XCTAssertNotNil(reader.location.cfi)
    }

    func testEPubRendersAndInvalidSavedLocationFallsBackToReadableText() async throws {
        let lease = try TemporaryDirectoryLease.writing(DocumentContentTests.minimalEPub(), filename: "book.epub")
        for lastLocation in [nil, "epubcfi(/6/999)"] as [String?] {
            let reader = try await open(lease.url.appendingPathComponent("book.epub"), lease: lease, lastLocation: lastLocation)
            defer { reader.close() }
            let text = try await reader.view.evaluateJavaScript("\(document).body.textContent") as? String
            XCTAssertTrue(text?.contains("Hello, World!") == true)
        }
    }

    func testEPubEstimatedPagesNavigateAcrossChaptersAndSurviveTypographyChanges() async throws {
        let data = try DocumentContentTests.minimalEPub(
            chapterText: String(repeating: "Readable words across the entire book. ", count: 1500), chapterCount: 2)
        let lease = try TemporaryDirectoryLease.writing(data, filename: "pages.epub")
        let reader = try await open(lease.url.appendingPathComponent("pages.epub"), lease: lease)
        defer { reader.close() }
        let count = try XCTUnwrap(reader.location.bookPages)
        XCTAssertGreaterThan(count, 10)
        XCTAssertEqual(reader.location.bookPage, 0)
        let target = count * 3 / 4
        let jumped = expectation(description: "Estimated page in second chapter")
        jumped.assertForOverFulfill = false
        var last: RelocateEvent?
        reader.coordinator.onRelocate = { event in
            last = event
            if event.sectionIndex == 1 { jumped.fulfill() }
        }
        reader.coordinator.bridgeGoToPage(target)
        await fulfillment(of: [jumped], timeout: 15)
        XCTAssertEqual(last?.bookPages, count)
        // An estimate can fall inside a rendered page; its start precedes the target.
        XCTAssertLessThanOrEqual(try XCTUnwrap(last?.bookPage), target)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(last?.bookPageEnd), target)
        XCTAssertGreaterThan(try XCTUnwrap(last?.bookPage), count / 2)
        let resized = expectation(description: "Typography relayout")
        resized.assertForOverFulfill = false
        reader.coordinator.onRelocate = { event in
            last = event
            resized.fulfill()
        }
        reader.coordinator.bridgeSetStyles("body { font-size: 30px; line-height: 1.8; }")
        await fulfillment(of: [resized], timeout: 15)
        XCTAssertEqual(last?.bookPages, count)
        let first = expectation(description: "First estimated page")
        first.assertForOverFulfill = false
        reader.coordinator.onRelocate = { event in
            if event.bookPage == 0 && event.sectionIndex == 0 { first.fulfill() }
        }
        reader.coordinator.bridgeGoToPage(0)
        await fulfillment(of: [first], timeout: 15)
        let before = try await reader.view.evaluateJavaScript("document.querySelector('foliate-view').lastLocation.cfi") as? String
        _ = try await reader.view.callAsyncJavaScript("await window.bridge.goToPage(-1); await window.bridge.goToPage(count);",
            arguments: ["count": count], in: nil, contentWorld: .page)
        let after = try await reader.view.evaluateJavaScript("document.querySelector('foliate-view').lastLocation.cfi") as? String
        XCTAssertEqual(after, before)
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
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return { window.isHidden = true }
        #endif
    }
}
