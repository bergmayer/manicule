import SwiftUI
import WebKit
import os.log

private nonisolated let webLog = Logger(subsystem: "com.palefire.manicule", category: "WebView")

/// Custom URL scheme used to serve local files to WKWebView,
/// bypassing App Sandbox restrictions on the WebKit content process.
private let epubScheme = "epub-local"

/// Configuration for loading content in the web view.
struct WebViewContent {
    let baseURL: URL
    let bookFileURL: URL
    var resourceBaseURL: URL? = nil
    var resourceLease: TemporaryDirectoryLease? = nil
    var scrollFraction: Double? = nil
    var textAnchor: TextAnchor? = nil

    /// All flowing formats load the same trusted host page.
    var schemeURL: URL { URL(string: "epub-local://bundle/reader.html")! }
}

/// Serves local files to WKWebView via a custom URL scheme.
///
/// Routes requests by host:
/// - `epub-local://local/<path>` — confined local files (path under baseURL)
/// - `epub-local://document/<path>` — resources beside a generated document
/// - `epub-local://bundle/<path>` — app bundle Resources directory
/// - `epub-local://book/<path>` — EPUB file for foliate-js to fetch
/// Generated publication manifests and sections share the bundle host origin.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated private static let mimeTypes: [String: String] = [
        "html": "text/html", "htm": "text/html",
        "xhtml": "application/xhtml+xml",
        "css": "text/css",
        "js": "application/javascript", "mjs": "application/javascript",
        "json": "application/json",
        "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff",
        "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf",
        "xml": "application/xml",
        "mp3": "audio/mpeg", "m4a": "audio/mp4",
        "wav": "audio/wav", "ogg": "audio/ogg",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
        "epub": "application/epub+zip",
    ]

    var baseURL: URL
    var documentResourceURL: URL?
    var bundleResourceURL: URL?
    var bookFileURL: URL?
    var resourceLease: TemporaryDirectoryLease?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let reader = ResourceReader()

    private actor ResourceReader {
        func read(_ url: URL, roots: Roots) throws -> (Data, String) {
            try Task.checkCancellation()
            let file = try roots.resolve(url)
            let data = try Data(contentsOf: file)
            try Task.checkCancellation()
            return (data, LocalFileSchemeHandler.mimeType(for: file.pathExtension))
        }
    }

    /// Immutable routing snapshot, retained until this request finishes.
    struct Roots: Sendable {
        let base: URL
        let document: URL?
        let bundle: URL?
        let book: URL?
        let lease: TemporaryDirectoryLease?

        nonisolated func resolve(_ request: URL) throws -> URL {
            let path = String(request.path.dropFirst())
            switch request.host {
            case "book" where path == "book.epub", "bundle" where path == "book.epub":
                guard path == "book.epub", let book else { throw URLError(.fileDoesNotExist) }
                return book
            case "bundle" where book?.pathExtension == "json" && (path == "publication.json" || path.hasPrefix("text/")):
                guard let book else { throw URLError(.fileDoesNotExist) }
                if path == "publication.json" { return book }
                guard let file = LocalFileSchemeHandler.resolvedFile(
                    relativePath: String(path.dropFirst(5)), under: book.deletingLastPathComponent()) else {
                    throw URLError(.noPermissionsToReadFile)
                }
                return file
            case "bundle":
                guard let bundle,
                      let file = LocalFileSchemeHandler.resolvedFile(relativePath: path, under: bundle) else {
                    throw URLError(.noPermissionsToReadFile)
                }
                if FileManager.default.fileExists(atPath: file.path) { return file }
                // Xcode flattens bundled resources, including vendor imports.
                guard let flattened = LocalFileSchemeHandler.resolvedFile(
                    relativePath: (path as NSString).lastPathComponent, under: bundle) else {
                    throw URLError(.noPermissionsToReadFile)
                }
                return flattened
            case "local":
                let file = URL(fileURLWithPath: request.path).standardizedFileURL
                guard LocalFileSchemeHandler.isContained(file, under: base) else {
                    throw URLError(.noPermissionsToReadFile)
                }
                return file
            case "document":
                guard let document,
                      let file = LocalFileSchemeHandler.resolvedFile(relativePath: path, under: document) else {
                    throw URLError(.noPermissionsToReadFile)
                }
                return file
            default: throw URLError(.unsupportedURL)
            }
        }
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let roots = Roots(base: baseURL, document: documentResourceURL,
                          bundle: bundleResourceURL, book: bookFileURL, lease: resourceLease)
        requests[id] = Task { [weak self, reader] in
            do {
                let (data, mimeType) = try await reader.read(url, roots: roots)
                try Task.checkCancellation()
                guard let self else { return }
                let encoding = mimeType.hasPrefix("text/") || mimeType.contains("javascript")
                    || mimeType.contains("json") || mimeType.contains("xml") ? "; charset=utf-8" : ""
                // fetch() in foliate requires a successful HTTP-style status,
                // even though these bytes come from a custom local scheme.
                guard let response = HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": mimeType + encoding, "Content-Length": String(data.count)
                    ]) else { throw URLError(.badServerResponse) }
                urlSchemeTask.didReceive(response)
                guard requests[id] != nil else { return }
                urlSchemeTask.didReceive(data)
                guard requests.removeValue(forKey: id) != nil else { return }
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, self?.requests.removeValue(forKey: id) != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() {
        for request in requests.values { request.cancel() }
        requests.removeAll()
    }

    /// Resolves a URL below `root`, rejecting dot components, absolute paths,
    /// NULs, and symlinks that escape the allowed directory.
    nonisolated static func resolvedFile(relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else { return nil }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }

        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        return isContained(candidate, under: root) ? candidate : nil
    }

    nonisolated static func isContained(_ fileURL: URL, under root: URL) -> Bool {
        let resolvedRoot = resolvingSymlinksThroughExistingAncestor(root)
        let resolvedFile = resolvingSymlinksThroughExistingAncestor(fileURL)
        let rootPath = resolvedRoot.path
        return resolvedFile.path == rootPath || resolvedFile.path.hasPrefix(rootPath + "/")
    }

    /// `URL.resolvingSymlinksInPath()` stops short when the leaf does not yet
    /// exist. Resolve the nearest existing ancestor first, then append any
    /// missing suffix, so an intermediate symlink cannot disguise an escape.
    nonisolated private static func resolvingSymlinksThroughExistingAncestor(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while existing.path != "/",
              !FileManager.default.fileExists(atPath: existing.path) {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }



    nonisolated static func mimeType(for ext: String) -> String {
        mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }
}

/// Proxy that allows parent views to request page navigation from the web view.
final class WebViewProxy {
    var nextPage: (() -> Void)?
    var previousPage: (() -> Void)?

    // Shared Foliate bridge methods
    var openAndInit: ((_ flow: String, _ css: String,
                       _ oneUpTB: Double, _ oneUpLR: Double,
                       _ twoUpTB: Double, _ twoUpLR: Double,
                       _ maxColumnCount: Int?, _ lastLocation: String?, _ coverOnRight: Bool) -> Void)?
    var goTo: ((String) -> Void)?              // CFI or href
    var goToFraction: ((Double) -> Void)?
    var goToPage: ((Int) -> Void)?
    var setFlow: ((String) -> Void)?           // "paginated" or "scrolled"
    var setStyles: ((String) -> Void)?
    /// Sets the foliate paginator column preference: nil = auto (orientation-driven,
    /// foliate re-resolves on resize), 1 = force single page, 2 = force two-up.
    var setColumnCount: ((Int?) -> Void)?
    var setPagePairing: ((Bool) -> Void)?
    /// Sends both margin pairs at once. The bridge stores both and picks
    /// one-up vs two-up automatically based on its resolved column count.
    /// Args: (oneUpTopBottom, oneUpLeftRight, twoUpTopBottom, twoUpLeftRight).
    var setMarginsBoth: ((Double, Double, Double, Double) -> Void)?
    var nextSection: (() -> Void)?               // ePub: go to next chapter/section
    var previousSection: (() -> Void)?            // ePub: go to previous chapter/section
    var goToTextAnchor: ((TextAnchor) -> Void)?
    var refocus: (() -> Void)?

    // ePub animation control
    var setAnimated: ((Bool) -> Void)?          // enable/disable page turn animation

    // ePub search methods
    var search: ((String) -> Void)?             // trigger search in foliate-js
    var clearSearch: (() -> Void)?              // clear search highlights
    var goToSearchResult: ((String) -> Void)?   // navigate to a search result by CFI

    // ePub read-aloud
    var captureViewportAnchor: (() -> Void)?     // capture center anchor before layout change
    var startReadAloud: (() -> Void)?           // begin read-aloud (extracts current section text)
    var highlightReadAloud: ((Int, Int) -> Void)?  // highlight range (start, length) in current section
    var clearReadAloud: (() -> Void)?           // clear read-aloud highlight
    var stopReadAloud: (() -> Void)?            // stop read-aloud mode
    var advanceReadAloudSection: (() -> Void)?  // advance to next section for read-aloud
    var scrollToReadAloudOffset: ((Int) -> Void)?  // scroll/navigate to make character offset visible
}

struct WebViewRepresentable {
    let content: WebViewContent
    var proxy: WebViewProxy? = nil
    // ePub bridge callbacks
    var onRelocate: ((_ event: RelocateEvent) -> Void)?
    var onBridgeReady: (() -> Void)?
    var onToggleChrome: (() -> Void)?
    var onSearchResult: ((_ results: [[String: String]], _ done: Bool) -> Void)?
    var onReadAloudSectionText: ((_ text: String, _ sectionIndex: Int, _ startOffset: Int) -> Void)?
    var onReadAloudSeek: ((_ offset: Int, _ sectionIndex: Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSearchFailure: ((String) -> Void)?

}

#if os(macOS)

extension WebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let handler = LocalFileSchemeHandler(baseURL: content.baseURL)
        handler.resourceLease = content.resourceLease
        handler.documentResourceURL = content.resourceBaseURL
        handler.bundleResourceURL = Bundle.main.resourceURL
        handler.bookFileURL = content.bookFileURL
        context.coordinator.schemeHandler = handler

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: epubScheme)
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "bridge")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        update(nsView, coordinator: context.coordinator) { [weak nsView] in
            DispatchQueue.main.async {
                guard let nsView else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: WebViewCoordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }
}

#else

extension WebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let handler = LocalFileSchemeHandler(baseURL: content.baseURL)
        handler.resourceLease = content.resourceLease
        handler.documentResourceURL = content.resourceBaseURL
        handler.bundleResourceURL = Bundle.main.resourceURL
        handler.bookFileURL = content.bookFileURL
        context.coordinator.schemeHandler = handler

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: epubScheme)
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "bridge")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.alwaysBounceVertical = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView

        // Ensure touch events reach JS quickly on iPhone
        webView.scrollView.delaysContentTouches = false

        // Foliate owns scrolling within its content frames.
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.isScrollEnabled = false

        // The bridge handles trackpad gestures in both page and scroll layouts.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(WebViewCoordinator.handleTrackpadPan(_:)))
        pan.allowedScrollTypesMask = .continuous
        pan.maximumNumberOfTouches = 0
        context.coordinator.trackpadPanRecognizer = pan
        webView.addGestureRecognizer(pan)

        // Finger pan recognizer for ePub scroll mode horizontal swipes.
        // In scroll mode, the browser steals JS touch events for its own
        // scrolling, making JS-based finger tracking unreliable.
        // A native UIKit recognizer avoids this problem entirely.
        do {
            let fingerPan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(WebViewCoordinator.handleFingerPan(_:))
            )
            fingerPan.minimumNumberOfTouches = 1
            fingerPan.maximumNumberOfTouches = 1
            fingerPan.delegate = context.coordinator
            context.coordinator.fingerPanRecognizer = fingerPan
            webView.addGestureRecognizer(fingerPan)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        update(uiView, coordinator: context.coordinator) { [weak uiView] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                uiView?.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: WebViewCoordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }
}

#endif

extension WebViewRepresentable {
    func update(_ nsView: WKWebView, coordinator coord: WebViewCoordinator, refocus: @escaping () -> Void) {
        coord.schemeHandler?.resourceLease = content.resourceLease
        coord.onRelocate = onRelocate
        coord.onBridgeReady = onBridgeReady
        coord.onToggleChrome = onToggleChrome
        coord.onSearchResult = onSearchResult
        coord.onReadAloudSectionText = onReadAloudSectionText
        coord.onReadAloudSeek = onReadAloudSeek
        coord.onFailure = onFailure
        coord.onSearchFailure = onSearchFailure

        coord.pendingScrollFraction = content.scrollFraction
        coord.pendingTextAnchor = content.textAnchor
        coord.wireProxy(proxy, refocus: refocus)
        coord.schemeHandler?.baseURL = content.baseURL
        coord.schemeHandler?.documentResourceURL = content.resourceBaseURL
        coord.schemeHandler?.bookFileURL = content.bookFileURL
        if coord.currentFileURL != content.schemeURL || coord.currentBookFileURL != content.bookFileURL {
            coord.currentFileURL = content.schemeURL
            coord.currentBookFileURL = content.bookFileURL
            coord.load(content.schemeURL, in: nsView)
        }
    }

}

/// Owns the shared Foliate bridge, navigation lifetime, and native gestures.
class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var schemeHandler: LocalFileSchemeHandler?
    var currentFileURL: URL?
    var currentBookFileURL: URL?
    private var tornDown = false

    deinit {
        tearDown()
    }

    /// Wire the reader proxy closures to coordinator bridge methods.
    func wireProxy(_ proxy: WebViewProxy?, refocus: @escaping () -> Void) {
        proxy?.nextPage = { [weak self] in self?.nextPage() }
        proxy?.previousPage = { [weak self] in self?.previousPage() }
        proxy?.openAndInit = { [weak self] flow, css, oneTB, oneLR, twoTB, twoLR, cols, loc, cover in
            self?.bridgeOpenAndInit(flow: flow, css: css,
                                    oneTB: oneTB, oneLR: oneLR,
                                    twoTB: twoTB, twoLR: twoLR,
                                    maxColumnCount: cols, lastLocation: loc, coverOnRight: cover)
        }
        proxy?.goTo = { [weak self] target in self?.bridgeGoTo(target) }
        proxy?.goToPage = { [weak self] page in self?.bridgeGoToPage(page) }
        proxy?.goToFraction = { [weak self] frac in self?.bridgeGoToFraction(frac) }
        proxy?.setFlow = { [weak self] mode in self?.bridgeSetFlow(mode) }
        proxy?.setStyles = { [weak self] css in self?.bridgeSetStyles(css) }
        proxy?.setColumnCount = { [weak self] n in self?.bridgeSetColumnCount(n) }
        proxy?.setPagePairing = { [weak self] shifted in
            self?.callBridge("window.bridge?.setPagePairing(shifted)", arguments: ["shifted": shifted])
        }
        proxy?.setMarginsBoth = { [weak self] oneTB, oneLR, twoTB, twoLR in
            self?.bridgeSetMarginsBoth(oneTB: oneTB, oneLR: oneLR, twoTB: twoTB, twoLR: twoLR)
        }
        proxy?.nextSection = { [weak self] in self?.bridgeNextSection() }
        proxy?.previousSection = { [weak self] in self?.bridgePreviousSection() }
        proxy?.setAnimated = { [weak self] enabled in self?.bridgeSetAnimated(enabled) }
        proxy?.search = { [weak self] query in self?.bridgeSearch(query) }
        proxy?.clearSearch = { [weak self] in self?.bridgeClearSearch() }
        proxy?.goToSearchResult = { [weak self] cfi in self?.bridgeGoToSearchResult(cfi) }
        proxy?.captureViewportAnchor = { [weak self] in self?.bridgeCaptureViewportAnchor() }
        proxy?.startReadAloud = { [weak self] in self?.bridgeStartReadAloud() }
        proxy?.highlightReadAloud = { [weak self] start, len in self?.bridgeHighlightReadAloud(start: start, length: len) }
        proxy?.clearReadAloud = { [weak self] in self?.bridgeClearReadAloud() }
        proxy?.stopReadAloud = { [weak self] in self?.bridgeStopReadAloud() }
        proxy?.advanceReadAloudSection = { [weak self] in self?.bridgeAdvanceReadAloudSection() }
        proxy?.scrollToReadAloudOffset = { [weak self] offset in self?.bridgeScrollToReadAloudOffset(offset) }
        proxy?.goToTextAnchor = { [weak self] anchor in self?.bridgeGoToTextAnchor(anchor) }
        proxy?.refocus = refocus
    }

    /// Remove script message handlers and stop the web view.
    /// Safe to call multiple times; only the first call has effect.
    private var searchRequestID: String?
    private var narrationRequestID: String?
    private var activeNavigation: WKNavigation?
    private var loadTimeout: Task<Void, Never>?
    private var didReportFailure = false

    func load(_ url: URL, in webView: WKWebView) {
        loadTimeout?.cancel()
        didReportFailure = false
        activeNavigation = webView.load(URLRequest(url: url))
        loadTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.reportFailure("The document renderer did not finish loading. Retry to reload it.")
        }
    }

    private func reportFailure(_ message: String) {
        loadTimeout?.cancel()
        guard !tornDown, !didReportFailure else { return }
        didReportFailure = true
        webLog.error("Renderer failed: \(message, privacy: .public)")
        onFailure?(message)
    }

    func tearDown() {
        loadTimeout?.cancel()
        guard !tornDown else { return }
        tornDown = true
        guard let wv = webView else { return }
        wv.stopLoading()
        schemeHandler?.cancelAll()
        wv.navigationDelegate = nil
        let cc = wv.configuration.userContentController
        cc.removeScriptMessageHandler(forName: "bridge")
        cc.removeAllUserScripts()
        #if os(iOS) || os(visionOS)
        if let pan = trackpadPanRecognizer, let v = pan.view {
            v.removeGestureRecognizer(pan)
        }
        trackpadPanRecognizer = nil
        #endif
    }

    // ePub bridge callbacks
    var onRelocate: ((_ event: RelocateEvent) -> Void)?
    var onBridgeReady: (() -> Void)?
    var onToggleChrome: (() -> Void)?
    var onSearchResult: ((_ results: [[String: String]], _ done: Bool) -> Void)?
    var onReadAloudSectionText: ((_ text: String, _ sectionIndex: Int, _ startOffset: Int) -> Void)?
    var onReadAloudSeek: ((_ offset: Int, _ sectionIndex: Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSearchFailure: ((String) -> Void)?

    // Initial source position for generated text publications
    var pendingScrollFraction: Double?
    var pendingTextAnchor: TextAnchor?

    #if os(iOS) || os(visionOS)
    var trackpadPanRecognizer: UIPanGestureRecognizer?
    var fingerPanRecognizer: UIPanGestureRecognizer?
    var epubFlowMode: String = "paginated"

    @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
        guard let wv = webView else { return }
        let tx = gesture.translation(in: gesture.view).x

        switch gesture.state {
        case .began:
            wv.evaluateJavaScript("window.bridge?.setPageOffset(0);")
        case .changed:
            wv.evaluateJavaScript("window.bridge?.setPageOffset(\(tx));")
        case .ended, .cancelled:
            let vx = gesture.velocity(in: gesture.view).x
            let threshold = (gesture.view?.bounds.width ?? 1000) * 0.3
            if abs(tx) > threshold || abs(vx) > 500 {
                let direction = tx < 0 ? 1 : -1
                wv.evaluateJavaScript("window.bridge?.commitPageTurn(\(direction));")
            } else {
                wv.evaluateJavaScript("window.bridge?.cancelPageTurn();")
            }
        default:
            break
        }
    }

    @objc func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let wv = webView else { return }
        let tx = gesture.translation(in: gesture.view).x

        switch gesture.state {
        case .began:
            wv.evaluateJavaScript("window.bridge?.setPageOffset(0);")
        case .changed:
            wv.evaluateJavaScript("window.bridge?.setPageOffset(\(tx));")
        case .ended, .cancelled:
            let vx = gesture.velocity(in: gesture.view).x
            let pageWidth = gesture.view?.bounds.width ?? 1000
            let threshold = pageWidth * 0.3
            if abs(tx) > threshold || abs(vx) > 500 {
                let direction = tx < 0 ? 1 : -1
                wv.evaluateJavaScript("window.bridge?.commitPageTurn(\(direction));")
            } else {
                wv.evaluateJavaScript("window.bridge?.cancelPageTurn();")
            }
        default:
            break
        }
    }

    // UIGestureRecognizerDelegate: only begin fingerPan in ePub scroll mode
    // and only for horizontal movements, so vertical scrolling is unaffected.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === fingerPanRecognizer {
            guard epubFlowMode != "paginated" else { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    // Allow finger pan to work alongside the webview's internal scroll
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === fingerPanRecognizer || gestureRecognizer === trackpadPanRecognizer {
            return true
        }
        return false
    }

    #endif

    func nextPage() { webView?.evaluateJavaScript("window.bridge?.next();") }
    func previousPage() { webView?.evaluateJavaScript("window.bridge?.prev();") }

    // MARK: - ePub bridge methods

    /// Send data as WebKit arguments, never as interpolated executable source.
    /// Ignore completions belonging to a closed or replaced publication.
    private func callBridge(_ script: String, arguments: [String: Any],
                            onError: ((String) -> Void)? = nil) {
        let publication = currentBookFileURL
        webView?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, !self.tornDown, self.currentBookFileURL == publication else { return }
            if case .failure(let error) = result {
                if let onError { onError(error.localizedDescription) }
                else { self.reportFailure(error.localizedDescription) }
            }
        }
    }

    func bridgeGoTo(_ target: String) {
        callBridge("await window.bridge?.goTo(target)", arguments: ["target": target])
    }

    func bridgeGoToPage(_ page: Int) {
        guard page >= 0 else { return }
        callBridge("await window.bridge?.goToPage(page)", arguments: ["page": page])
    }

    func bridgeGoToFraction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        callBridge("await window.bridge?.goToFraction(fraction)", arguments: ["fraction": min(1, max(0, fraction))])
    }

    func bridgeSetFlow(_ mode: String) {
        callBridge("window.bridge?.setFlow(mode)", arguments: ["mode": mode])
    }

    func bridgeSetStyles(_ css: String) {
        callBridge("window.bridge?.setStyles(css)", arguments: ["css": css])
    }

    func bridgeSetColumnCount(_ count: Int?) {
        callBridge("window.bridge?.setColumnCount(columns)", arguments: ["columns": count.map { $0 as Any } ?? "auto"])
    }

    func bridgeSetMarginsBoth(oneTB: Double, oneLR: Double, twoTB: Double, twoLR: Double) {
        guard [oneTB, oneLR, twoTB, twoLR].allSatisfy(\.isFinite) else { return }
        callBridge("window.bridge?.setMarginsBoth(oneTB, oneLR, twoTB, twoLR)",
            arguments: ["oneTB": oneTB, "oneLR": oneLR, "twoTB": twoTB, "twoLR": twoLR])
    }

    func bridgeNextSection() {
        webView?.evaluateJavaScript("window.bridge?.nextSection();")
    }

    func bridgePreviousSection() {
        webView?.evaluateJavaScript("window.bridge?.prevSection();")
    }

    func bridgeSearch(_ query: String) {
        let requestID = UUID().uuidString
        searchRequestID = requestID
        callBridge("await window.bridge?.search(query, requestID)", arguments: ["query": query, "requestID": requestID]) { [weak self] message in
            guard self?.searchRequestID == requestID else { return }
            self?.onSearchFailure?(message)
        }
    }

    func bridgeClearSearch() {
        searchRequestID = nil
        webView?.evaluateJavaScript("window.bridge?.clearSearch();")
    }

    func bridgeGoToSearchResult(_ cfi: String) {
        callBridge("await window.bridge?.goToSearchResult(cfi)", arguments: ["cfi": cfi])
    }

    func bridgeSetAnimated(_ enabled: Bool) {
        webView?.evaluateJavaScript("window.bridge?.setAnimated(\(enabled));")
    }

    func bridgeCaptureViewportAnchor() {
        webView?.evaluateJavaScript("window.bridge?.captureViewportAnchor();")
    }

    func bridgeStartReadAloud() {
        let requestID = UUID().uuidString
        narrationRequestID = requestID
        webView?.evaluateJavaScript("window.bridge?.startReadAloud('\(requestID)');")
    }

    func bridgeHighlightReadAloud(start: Int, length: Int) {
        webView?.evaluateJavaScript("window.bridge?.highlightReadAloud(\(start), \(length));")
    }

    func bridgeClearReadAloud() {
        webView?.evaluateJavaScript("window.bridge?.clearReadAloud();")
    }

    func bridgeStopReadAloud() {
        narrationRequestID = nil
        webView?.evaluateJavaScript("window.bridge?.stopReadAloud();")
    }

    func bridgeAdvanceReadAloudSection() {
        webView?.evaluateJavaScript("window.bridge?.advanceReadAloudSection();")
    }

    func bridgeScrollToReadAloudOffset(_ offset: Int) {
        webView?.evaluateJavaScript("window.bridge?.scrollToReadAloudOffset(\(offset));")
    }

    func bridgeGoToTextAnchor(_ anchor: TextAnchor) {
        guard let data = try? JSONEncoder().encode(anchor),
              let value = try? JSONSerialization.jsonObject(with: data) else { return }
        callBridge("await window.bridge?.goToTextAnchor(anchor)", arguments: ["anchor": value])
    }

    private var publicationURL: String {
        guard let file = currentBookFileURL, file.pathExtension == "json" else {
            return "\(epubScheme)://bundle/book.epub"
        }
        return "\(epubScheme)://bundle/publication.json"
    }

    /// Opens the publication and applies all initial settings in a single chained async call.
    func bridgeOpenAndInit(flow: String, css: String,
                           oneTB: Double, oneLR: Double,
                           twoTB: Double, twoLR: Double,
                           maxColumnCount: Int?, lastLocation: String?, coverOnRight: Bool = false) {
        var options: [String: Any] = ["showTextStart": true]
        if let lastLocation { options = ["lastLocation": lastLocation] }
        if let anchor = pendingTextAnchor, let data = try? JSONEncoder().encode(anchor),
           let value = try? JSONSerialization.jsonObject(with: data) {
            options["textAnchor"] = value
        } else if let fraction = pendingScrollFraction, fraction.isFinite {
            options["fraction"] = min(1, max(0, fraction))
        }
        // WebKit serializes arguments, so file names, CSS, and saved passages
        // never become executable JavaScript through string interpolation.
        callBridge("""
            await window.bridge.open(url);
            window.bridge.setFlow(flow);
            window.bridge.setStyles(css);
            window.bridge.setMarginsBoth(oneTB, oneLR, twoTB, twoLR);
            await window.bridge.setPagePairing(coverOnRight);
            window.bridge.setColumnCount(columns);
            await window.bridge.init(options);
            """, arguments: ["url": publicationURL, "flow": flow, "css": css,
                "oneTB": oneTB, "oneLR": oneLR, "twoTB": twoTB, "twoLR": twoLR,
                "coverOnRight": coverOnRight, "columns": maxColumnCount.map { $0 as Any } ?? "auto", "options": options])
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let policy = MainActor.assumeIsolated {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                return WKNavigationActionPolicy.cancel
            }

            // Reader links belong in the system browser/mail app. Do not let
            // an untrusted publication replace either the host page or one of
            // its content frames with a network document.
            if navigationAction.navigationType == .linkActivated,
               ["http", "https", "mailto", "tel"].contains(scheme) {
                openExternally(url)
                return .cancel
            }

            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if isMainFrame {
                // The only main-frame navigation allowed is the exact host or
                // generated-document URL that Swift asked WebKit to load.
                return url == currentFileURL ? .allow : .cancel
            }

            // Foliate renders replaced publication resources in blob frames.
            // about:blank is used while those frames are being constructed.
            return [epubScheme, "blob", "about"].contains(scheme) ? .allow : .cancel
        }
        decisionHandler(policy)
    }

    private func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { navigationFailed(navigation, error: error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { navigationFailed(navigation, error: error) }
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === activeNavigation,
              (error as NSError).code != NSURLErrorCancelled else { return }
        reportFailure(error.localizedDescription)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            reportFailure("The document renderer stopped unexpectedly. Retry to reload it at your saved position.")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            #if os(macOS)
            DispatchQueue.main.async { [weak webView] in
                guard let webView else { return }
                webView.window?.makeFirstResponder(webView)
            }
            #endif
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }

            if message.name == "bridge" {
                handleBridgeMessage(body)

            }
        }
    }

    private func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }

        switch type {
        case "bridgeReady":
            webLog.info("Bridge ready")
            onBridgeReady?()
        case "relocate":
            loadTimeout?.cancel()
            let event = RelocateEvent(from: body)
            onRelocate?(event)
        case "load":
            break // Section loaded
        case "bookOpened":
            webLog.info("Book opened")
        case "externalLink":
            if let href = body["href"] as? String,
               let url = URL(string: href),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto", "tel"].contains(scheme) {
                openExternally(url)
            }
        case "flowChanged":
            #if os(iOS) || os(visionOS)
            if let flow = body["flow"] as? String {
                epubFlowMode = flow
            }
            #endif
        case "toggleChrome":
            onToggleChrome?()
        case "searchResult":
            guard let searchRequestID, body["requestID"] as? String == searchRequestID else { return }
            let results = body["results"] as? [[String: Any]] ?? []
            let done = body["done"] as? Bool ?? true
            let mapped = results.map { item -> [String: String] in
                var entry: [String: String] = [:]
                if let cfi = item["cfi"] as? String { entry["cfi"] = cfi }
                if let excerpt = item["excerpt"] as? String { entry["excerpt"] = excerpt }
                if let label = item["label"] as? String { entry["label"] = label }
                return entry
            }
            onSearchResult?(mapped, done)
        case "readAloudSectionText":
            guard let narrationRequestID, body["requestID"] as? String == narrationRequestID else { return }
            let text = body["text"] as? String ?? ""
            let sectionIndex = body["sectionIndex"] as? Int ?? -1
            let startOffset = body["startOffset"] as? Int ?? 0
            onReadAloudSectionText?(text, sectionIndex, startOffset)
        case "readAloudSeek":
            guard let narrationRequestID, body["requestID"] as? String == narrationRequestID else { return }
            let offset = body["offset"] as? Int ?? 0
            let sectionIndex = body["sectionIndex"] as? Int ?? -1
            onReadAloudSeek?(offset, sectionIndex)
        case "searchError":
            guard let searchRequestID, body["requestID"] as? String == searchRequestID else { return }
            onSearchFailure?(body["message"] as? String ?? "Search could not finish.")
        case "error":
            reportFailure(body["message"] as? String ?? "The publication could not be rendered.")
        case "diagnostic":
            webLog.info("Bridge: \(String(describing: body["message"]), privacy: .public)")
        default:
            break
        }
    }


}

#if os(iOS) || os(visionOS)
extension WebViewCoordinator: UIGestureRecognizerDelegate {}
#endif
