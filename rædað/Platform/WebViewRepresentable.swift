import SwiftUI
import WebKit
import os.log

private nonisolated let webLog = Logger(subsystem: "com.palefire.raedad", category: "WebView")

/// Custom URL scheme used to serve local files to WKWebView,
/// bypassing App Sandbox restrictions on the WebKit content process.
private let epubScheme = "epub-local"

/// Configuration for loading content in the web view.
struct WebViewContent: Equatable {
    let fileURL: URL              // HTML file to load (or ignored for ePub)
    let baseURL: URL              // extraction root directory (text reader) or ignored (ePub)
    let scrollFraction: Double?   // nil = don't restore, 0.0-1.0 = restore to fraction
    let fragment: String?         // optional anchor to scroll to (e.g., "section2")
    let cssOverride: String?      // custom CSS to inject into the page
    var startAtEnd: Bool = false  // start at last page of chapter (when going backwards)
    var paginated: Bool = true    // true = column pagination, false = vertical scroll
    var twoUp: Bool? = nil        // nil = auto, true/false = manual override
    var isEPub: Bool = false      // true = foliate-js ePub mode
    var bookFileURL: URL? = nil   // EPUB file URL for scheme handler (ePub mode only)
    // Text reader paginated mode: both margin pairs are sent so the JS bridge
    // can pick the right one based on its resolved column count and re-pick
    // when the layout flips on rotation, without a Swift round trip.
    var marginsOneUp: MarginSettings? = nil
    var marginsTwoUp: MarginSettings? = nil

    static func == (lhs: WebViewContent, rhs: WebViewContent) -> Bool {
        if lhs.isEPub != rhs.isEPub { return false }
        if lhs.isEPub {
            // ePub content only changes when a different book is loaded
            return lhs.bookFileURL == rhs.bookFileURL
        }
        return lhs.fileURL == rhs.fileURL && lhs.fragment == rhs.fragment
            && lhs.cssOverride == rhs.cssOverride && lhs.paginated == rhs.paginated
            && lhs.twoUp == rhs.twoUp
    }

    /// Builds a custom-scheme URL for loading through the scheme handler.
    var schemeURL: URL {
        if isEPub {
            // Load the bundled reader.html host page
            var components = URLComponents()
            components.scheme = epubScheme
            components.host = "bundle"
            components.path = "/reader.html"
            return components.url!
        }
        // Text reader: full file path encoded into the URL path
        var components = URLComponents()
        components.scheme = epubScheme
        components.host = "local"
        components.path = fileURL.path
        return components.url!
    }
}

/// Serves local files to WKWebView via a custom URL scheme.
///
/// Routes requests by host:
/// - `epub-local://local/<path>` — existing text reader files (path under baseURL)
/// - `epub-local://bundle/<path>` — app bundle Resources directory
/// - `epub-local://book/<path>` — EPUB file for foliate-js to fetch
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    var baseURL: URL
    var bundleResourceURL: URL?
    var bookFileURL: URL?

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let host = requestURL.host ?? ""
        webLog.debug("scheme: \(host, privacy: .public):\(requestURL.path, privacy: .public)")

        switch host {
        case "bundle":
            serveBundleResource(requestURL: requestURL, task: urlSchemeTask)
        case "book":
            serveBookFile(requestURL: requestURL, task: urlSchemeTask)
        default:
            serveLocalFile(requestURL: requestURL, task: urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    // MARK: - Route handlers

    private func serveBundleResource(requestURL: URL, task: any WKURLSchemeTask) {
        let relativePath = String(requestURL.path.dropFirst())

        // Serve book.epub from the bookFileURL (same origin to avoid CORS issues)
        if relativePath == "book.epub" || relativePath.hasSuffix("/book.epub") {
            serveBookFile(requestURL: requestURL, task: task)
            return
        }

        guard let bundleURL = bundleResourceURL else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        var fileURL = bundleURL.appendingPathComponent(relativePath)

        // Xcode flattens resource directories. If the exact path doesn't exist,
        // fall back to just the filename (handles foliate-js/vendor/* imports).
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let filename = (relativePath as NSString).lastPathComponent
            fileURL = bundleURL.appendingPathComponent(filename)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeType(for: fileURL.pathExtension)
        respond(task: task, url: requestURL, data: data, mimeType: mimeType)
    }

    private func serveBookFile(requestURL: URL, task: any WKURLSchemeTask) {
        guard let bookURL = bookFileURL,
              let data = try? Data(contentsOf: bookURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        respond(task: task, url: requestURL, data: data, mimeType: "application/epub+zip")
    }

    private func serveLocalFile(requestURL: URL, task: any WKURLSchemeTask) {
        let filePath = requestURL.path
        let fileURL = URL(fileURLWithPath: filePath).standardized

        // Component-boundary check: a plain prefix test would also admit
        // sibling directories like ".../base-evil" for base ".../base".
        let basePath = baseURL.standardized.path
        guard fileURL.path == basePath || fileURL.path.hasPrefix(basePath + "/") else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeType(for: fileURL.pathExtension)
        respond(task: task, url: requestURL, data: data, mimeType: mimeType)
    }

    private func respond(task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let encoding = mimeType.hasPrefix("text/") || mimeType.contains("javascript")
            || mimeType.contains("json") || mimeType.contains("xml")
            ? "; charset=utf-8" : ""
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(mimeType)\(encoding)",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "xhtml": return "application/xhtml+xml"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "xml": return "application/xml"
        case "epub": return "application/epub+zip"
        default: return "application/octet-stream"
        }
    }
}

/// Proxy that allows parent views to request page navigation from the web view.
final class WebViewProxy {
    var nextPage: (() -> Void)?
    var previousPage: (() -> Void)?

    // ePub bridge methods
    var openBook: (() -> Void)?                // trigger book opening in foliate-js
    var initBook: ((String?) -> Void)?         // initialize with optional last CFI
    var openAndInit: ((_ flow: String, _ css: String,
                       _ oneUpTB: Double, _ oneUpLR: Double,
                       _ twoUpTB: Double, _ twoUpLR: Double,
                       _ maxColumnCount: Int?, _ lastLocation: String?) -> Void)?
    var goTo: ((String) -> Void)?              // CFI or href
    var goToFraction: ((Double) -> Void)?
    var setFlow: ((String) -> Void)?           // "paginated" or "scrolled"
    var setStyles: ((String) -> Void)?
    /// Sets the foliate paginator column preference: nil = auto (orientation-driven,
    /// foliate re-resolves on resize), 1 = force single page, 2 = force two-up.
    var setColumnCount: ((Int?) -> Void)?
    /// Single-pair setter (legacy). Applies the same margins to both layouts.
    /// New callers should use `setMarginsBoth` so the bridge can pick the
    /// right pair when the resolved column count flips on rotation.
    var setMargins: ((Double, Double) -> Void)?
    /// Sends both margin pairs at once. The bridge stores both and picks
    /// one-up vs two-up automatically based on its resolved column count.
    /// Args: (oneUpTopBottom, oneUpLeftRight, twoUpTopBottom, twoUpLeftRight).
    var setMarginsBoth: ((Double, Double, Double, Double) -> Void)?
    var nextSection: (() -> Void)?               // ePub: go to next chapter/section
    var previousSection: (() -> Void)?            // ePub: go to previous chapter/section
    var goToPage: ((Int) -> Void)?              // text reader paginated: go to page index (animated)
    var goToPageImmediate: ((Int) -> Void)?     // text reader paginated: go to page index (no animation)
    var goToAnchor: ((String) -> Void)?         // text reader: scroll to anchor id
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

#if os(macOS)

struct WebViewRepresentable: NSViewRepresentable {
    let content: WebViewContent
    var proxy: WebViewProxy? = nil
    var onScrollPositionChange: ((Double) -> Void)?
    var onPageInfo: ((_ currentPage: Int, _ totalPages: Int) -> Void)?
    var onBoundaryReached: ((_ direction: BoundaryDirection) -> Void)?
    // ePub bridge callbacks
    var onRelocate: ((_ event: RelocateEvent) -> Void)?
    var onBridgeReady: (() -> Void)?
    var onToggleChrome: (() -> Void)?
    var onSearchResult: ((_ results: [[String: String]], _ done: Bool) -> Void)?
    var onReadAloudSectionText: ((_ text: String, _ sectionIndex: Int, _ startOffset: Int) -> Void)?
    var onReadAloudSeek: ((_ offset: Int, _ sectionIndex: Int) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let handler = LocalFileSchemeHandler(baseURL: content.baseURL)
        if content.isEPub {
            handler.bundleResourceURL = Bundle.main.resourceURL
            handler.bookFileURL = content.bookFileURL
        }
        context.coordinator.schemeHandler = handler
        context.coordinator.isEPub = content.isEPub

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: epubScheme)
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "pageHandler")
        contentController.add(context.coordinator, name: "bridge")
        if !content.isEPub {
            // Hide content before first paint to prevent flash of unstyled text (text reader only)
            let hideScript = WKUserScript(
                source: "document.documentElement.style.setProperty('visibility', 'hidden', 'important');",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            contentController.addUserScript(hideScript)
        }
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.onScrollPositionChange = onScrollPositionChange
        coord.onPageInfo = onPageInfo
        coord.onBoundaryReached = onBoundaryReached
        coord.onRelocate = onRelocate
        coord.onBridgeReady = onBridgeReady
        coord.onToggleChrome = onToggleChrome
        coord.onSearchResult = onSearchResult
        coord.onReadAloudSectionText = onReadAloudSectionText
        coord.onReadAloudSeek = onReadAloudSeek

        if content.isEPub {
            coord.wireEPubProxy(proxy) { [weak nsView] in
                DispatchQueue.main.async {
                    guard let wv = nsView else { return }
                    wv.window?.makeFirstResponder(wv)
                }
            }

            // ePub: update scheme handler book URL
            coord.schemeHandler?.bookFileURL = content.bookFileURL

            // Load reader.html if not loaded yet
            if coord.currentFileURL != content.schemeURL {
                coord.currentFileURL = content.schemeURL
                nsView.load(URLRequest(url: content.schemeURL))
            }
        } else {
            // Text reader mode: existing behavior
            coord.pendingScrollFraction = content.scrollFraction
            coord.pendingFragment = content.fragment
            coord.pendingCSS = content.cssOverride
            coord.startAtEnd = content.startAtEnd
            let paginatedChanged = coord.paginated != content.paginated
            coord.paginated = content.paginated
            coord.schemeHandler?.baseURL = content.baseURL
            coord.wireTextProxy(proxy) { [weak nsView] in
                DispatchQueue.main.async {
                    guard let wv = nsView else { return }
                    wv.window?.makeFirstResponder(wv)
                }
            }

            if coord.currentFileURL != content.fileURL || paginatedChanged {
                coord.currentFileURL = content.fileURL
                coord.currentMarginsOneUp = content.marginsOneUp
                coord.currentMarginsTwoUp = content.marginsTwoUp
                coord.currentTwoUp = content.twoUp
                nsView.load(URLRequest(url: content.schemeURL))
            } else if coord.currentCSS != content.cssOverride {
                coord.injectCSS(into: nsView)
            }

            if coord.currentMarginsOneUp != content.marginsOneUp || coord.currentMarginsTwoUp != content.marginsTwoUp,
               let one = content.marginsOneUp, let two = content.marginsTwoUp {
                coord.currentMarginsOneUp = one
                coord.currentMarginsTwoUp = two
                coord.textReaderSetMarginsBoth(one: one, two: two)
            }

            if coord.currentTwoUp != content.twoUp {
                coord.currentTwoUp = content.twoUp
                coord.applyTwoUp(content.twoUp, to: nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: WebViewCoordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }
}

#else

struct WebViewRepresentable: UIViewRepresentable {
    let content: WebViewContent
    var proxy: WebViewProxy? = nil
    var onScrollPositionChange: ((Double) -> Void)?
    var onPageInfo: ((_ currentPage: Int, _ totalPages: Int) -> Void)?
    var onBoundaryReached: ((_ direction: BoundaryDirection) -> Void)?
    // ePub bridge callbacks
    var onRelocate: ((_ event: RelocateEvent) -> Void)?
    var onBridgeReady: (() -> Void)?
    var onToggleChrome: (() -> Void)?
    var onSearchResult: ((_ results: [[String: String]], _ done: Bool) -> Void)?
    var onReadAloudSectionText: ((_ text: String, _ sectionIndex: Int, _ startOffset: Int) -> Void)?
    var onReadAloudSeek: ((_ offset: Int, _ sectionIndex: Int) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let handler = LocalFileSchemeHandler(baseURL: content.baseURL)
        if content.isEPub {
            handler.bundleResourceURL = Bundle.main.resourceURL
            handler.bookFileURL = content.bookFileURL
        }
        context.coordinator.schemeHandler = handler
        context.coordinator.isEPub = content.isEPub

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: epubScheme)
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "pageHandler")
        contentController.add(context.coordinator, name: "bridge")
        if !content.isEPub {
            let hideScript = WKUserScript(
                source: "document.documentElement.style.setProperty('visibility', 'hidden', 'important');",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            contentController.addUserScript(hideScript)
        }
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

        if content.isEPub {
            // ePub mode: foliate-js manages all scrolling internally
            webView.scrollView.isPagingEnabled = false
            webView.scrollView.isScrollEnabled = false
        } else {
            // Text reader mode: JS owns horizontal scrolling in paginated mode
            if content.paginated {
                webView.scrollView.isPagingEnabled = false
                webView.scrollView.isScrollEnabled = false
            } else {
                webView.scrollView.isPagingEnabled = false
                webView.scrollView.isScrollEnabled = true
            }
        }

        // Trackpad pan recognizer — always active for ePub (bridge handles
        // mode-specific behavior), paginated-only for text reader
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(WebViewCoordinator.handleTrackpadPan(_:)))
        pan.allowedScrollTypesMask = .continuous
        pan.maximumNumberOfTouches = 0
        context.coordinator.trackpadPanRecognizer = pan
        if content.isEPub || content.paginated {
            webView.addGestureRecognizer(pan)
        }

        // Finger pan recognizer for ePub scroll mode horizontal swipes.
        // In scroll mode, the browser steals JS touch events for its own
        // scrolling, making JS-based finger tracking unreliable.
        // A native UIKit recognizer avoids this problem entirely.
        if content.isEPub {
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
        let coord = context.coordinator
        coord.onScrollPositionChange = onScrollPositionChange
        coord.onPageInfo = onPageInfo
        coord.onBoundaryReached = onBoundaryReached
        coord.onRelocate = onRelocate
        coord.onBridgeReady = onBridgeReady
        coord.onToggleChrome = onToggleChrome
        coord.onSearchResult = onSearchResult
        coord.onReadAloudSectionText = onReadAloudSectionText
        coord.onReadAloudSeek = onReadAloudSeek

        if content.isEPub {
            coord.wireEPubProxy(proxy) { [weak uiView] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    uiView?.becomeFirstResponder()
                }
            }

            coord.schemeHandler?.bookFileURL = content.bookFileURL

            // ePub: always keep trackpad recognizer (bridge handles mode)
            if let pan = coord.trackpadPanRecognizer, pan.view == nil {
                uiView.addGestureRecognizer(pan)
            }

            if coord.currentFileURL != content.schemeURL {
                coord.currentFileURL = content.schemeURL
                uiView.load(URLRequest(url: content.schemeURL))
            }
        } else {
            coord.pendingScrollFraction = content.scrollFraction
            coord.pendingFragment = content.fragment
            coord.pendingCSS = content.cssOverride
            coord.startAtEnd = content.startAtEnd
            let paginatedChanged = coord.paginated != content.paginated
            coord.paginated = content.paginated
            coord.schemeHandler?.baseURL = content.baseURL
            coord.wireTextProxy(proxy) { [weak uiView] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    uiView?.becomeFirstResponder()
                }
            }

            // Update scroll behavior for mode changes
            if content.paginated {
                uiView.scrollView.isPagingEnabled = false
                uiView.scrollView.isScrollEnabled = false
            } else {
                uiView.scrollView.isPagingEnabled = false
                uiView.scrollView.isScrollEnabled = true
            }

            // Add/remove trackpad recognizer based on pagination mode
            if let pan = coord.trackpadPanRecognizer {
                if content.paginated && pan.view == nil {
                    uiView.addGestureRecognizer(pan)
                } else if !content.paginated && pan.view != nil {
                    uiView.removeGestureRecognizer(pan)
                }
            }

            if coord.currentFileURL != content.fileURL || paginatedChanged {
                coord.currentFileURL = content.fileURL
                coord.currentMarginsOneUp = content.marginsOneUp
                coord.currentMarginsTwoUp = content.marginsTwoUp
                coord.currentTwoUp = content.twoUp
                uiView.load(URLRequest(url: content.schemeURL))
            } else if coord.currentCSS != content.cssOverride {
                coord.injectCSS(into: uiView)
            }

            if coord.currentMarginsOneUp != content.marginsOneUp || coord.currentMarginsTwoUp != content.marginsTwoUp,
               let one = content.marginsOneUp, let two = content.marginsTwoUp {
                coord.currentMarginsOneUp = one
                coord.currentMarginsTwoUp = two
                coord.textReaderSetMarginsBoth(one: one, two: two)
            }

            if coord.currentTwoUp != content.twoUp {
                coord.currentTwoUp = content.twoUp
                coord.applyTwoUp(content.twoUp, to: uiView)
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: WebViewCoordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }
}

#endif

enum BoundaryDirection {
    case previous
    case next
}

/// Shared coordinator that handles WKWebView navigation for both ePub (foliate-js)
/// and text reader (legacy readerScript) modes.
class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var schemeHandler: LocalFileSchemeHandler?
    var currentFileURL: URL?
    var isEPub: Bool = false
    private var tornDown = false

    deinit {
        tearDown()
    }

    /// Wire the ePub proxy closures to coordinator bridge methods.
    func wireEPubProxy(_ proxy: WebViewProxy?, refocus: @escaping () -> Void) {
        proxy?.nextPage = { [weak self] in self?.nextPage() }
        proxy?.previousPage = { [weak self] in self?.previousPage() }
        proxy?.openBook = { [weak self] in self?.bridgeOpenBook() }
        proxy?.initBook = { [weak self] cfi in self?.bridgeInit(lastLocation: cfi) }
        proxy?.openAndInit = { [weak self] flow, css, oneTB, oneLR, twoTB, twoLR, cols, loc in
            self?.bridgeOpenAndInit(flow: flow, css: css,
                                    oneTB: oneTB, oneLR: oneLR,
                                    twoTB: twoTB, twoLR: twoLR,
                                    maxColumnCount: cols, lastLocation: loc)
        }
        proxy?.goTo = { [weak self] target in self?.bridgeGoTo(target) }
        proxy?.goToFraction = { [weak self] frac in self?.bridgeGoToFraction(frac) }
        proxy?.setFlow = { [weak self] mode in self?.bridgeSetFlow(mode) }
        proxy?.setStyles = { [weak self] css in self?.bridgeSetStyles(css) }
        proxy?.setColumnCount = { [weak self] n in self?.bridgeSetColumnCount(n) }
        proxy?.setMargins = { [weak self] tb, lr in self?.bridgeSetMargins(topBottom: tb, leftRight: lr) }
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
        proxy?.refocus = refocus
    }

    /// Wire the text reader proxy closures to coordinator methods.
    func wireTextProxy(_ proxy: WebViewProxy?, refocus: @escaping () -> Void) {
        proxy?.nextPage = { [weak self] in self?.nextPage() }
        proxy?.previousPage = { [weak self] in self?.previousPage() }
        proxy?.goToPage = { [weak self] page in self?.textReaderGoToPage(page) }
        proxy?.goToPageImmediate = { [weak self] page in self?.textReaderGoToPage(page, animate: false) }
        proxy?.goToAnchor = { [weak self] id in self?.textReaderGoToAnchor(id) }
        proxy?.refocus = refocus
    }

    /// Remove script message handlers and stop the web view.
    /// Safe to call multiple times; only the first call has effect.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        let cc = wv.configuration.userContentController
        cc.removeScriptMessageHandler(forName: "pageHandler")
        cc.removeScriptMessageHandler(forName: "bridge")
        cc.removeAllUserScripts()
        #if os(iOS)
        if let pan = trackpadPanRecognizer, let v = pan.view {
            v.removeGestureRecognizer(pan)
        }
        trackpadPanRecognizer = nil
        #endif
    }

    // Text reader callbacks
    var onScrollPositionChange: ((Double) -> Void)?
    var onPageInfo: ((_ currentPage: Int, _ totalPages: Int) -> Void)?
    var onBoundaryReached: ((_ direction: BoundaryDirection) -> Void)?

    // ePub bridge callbacks
    var onRelocate: ((_ event: RelocateEvent) -> Void)?
    var onBridgeReady: (() -> Void)?
    var onToggleChrome: (() -> Void)?
    var onSearchResult: ((_ results: [[String: String]], _ done: Bool) -> Void)?
    var onReadAloudSectionText: ((_ text: String, _ sectionIndex: Int, _ startOffset: Int) -> Void)?
    var onReadAloudSeek: ((_ offset: Int, _ sectionIndex: Int) -> Void)?

    // Text reader state
    var pendingScrollFraction: Double?
    var pendingFragment: String?
    var pendingCSS: String?
    var currentCSS: String?
    var startAtEnd: Bool = false
    var paginated: Bool = true
    var currentTwoUp: Bool? = nil
    var currentMarginsOneUp: MarginSettings? = nil
    var currentMarginsTwoUp: MarginSettings? = nil

    #if os(iOS)
    var trackpadPanRecognizer: UIPanGestureRecognizer?
    var fingerPanRecognizer: UIPanGestureRecognizer?
    var epubFlowMode: String = "paginated"

    @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
        guard let wv = webView else { return }
        let tx = gesture.translation(in: gesture.view).x

        switch gesture.state {
        case .began:
            if isEPub {
                wv.evaluateJavaScript("window.bridge?.setPageOffset(0);")
            } else {
                wv.evaluateJavaScript("window.raedad?.panStart();")
            }
        case .changed:
            if isEPub {
                wv.evaluateJavaScript("window.bridge?.setPageOffset(\(tx));")
            } else {
                wv.evaluateJavaScript("window.raedad?.panMove(\(tx));")
            }
        case .ended, .cancelled:
            let vx = gesture.velocity(in: gesture.view).x
            if isEPub {
                let pageWidth = gesture.view?.bounds.width ?? 1000
                let threshold = pageWidth * 0.3
                if abs(tx) > threshold || abs(vx) > 500 {
                    let direction = tx < 0 ? 1 : -1
                    wv.evaluateJavaScript("window.bridge?.commitPageTurn(\(direction));")
                } else {
                    wv.evaluateJavaScript("window.bridge?.cancelPageTurn();")
                }
            } else {
                // Convert velocity from points/sec to normalized scale
                let normalizedVelocity = -vx / 1000.0
                wv.evaluateJavaScript("window.raedad?.panEnd(\(normalizedVelocity));")
            }
        default:
            break
        }
    }

    @objc func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let wv = webView, isEPub else { return }
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
            guard isEPub, epubFlowMode != "paginated" else { return false }
            let pan = gestureRecognizer as! UIPanGestureRecognizer
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

    // MARK: - Text reader JavaScript (used only for text/markdown reader)

    private let readerScript = """
    (function() {
        if (window.raedad) return;

        // MARGIN_TB / MARGIN_LR are the *active* margin values for the
        // currently-rendered layout. They're picked from marginsOneUp /
        // marginsTwoUp inside updateColumnMetrics so when isTwoPage flips
        // on rotation, the matching pair takes over without a Swift round trip.
        var MARGIN_TB = 48;
        var MARGIN_LR = 48;
        var marginsOneUp = { tb: 48, lr: 48 };
        var marginsTwoUp = { tb: 48, lr: 48 };
        var currentMode = null;

        // --- Shared state ---
        var scroller, container, viewportStyle, columnStyle;
        var currentPageIdx = 0;
        var animationId = null;
        var pageTurnLock = false;
        var forceTwoUp = null;
        var isTwoPage = false;
        var cachedColWidth = 0;
        var cachedColGap = 0;

        // --- DOM anchor for position preservation across resize ---
        // Mirrors the ePub paginator approach: anchor is a DOM Range
        // pointing to the start of visible content. Only updated on
        // user page turns, never during resize.
        var currentAnchor = null; // DOM Range

        function getVisibleRange() {
            // Walk the DOM to find the first visible text node in the
            // current column, then binary-search for the exact offset.
            var sl = getScrollLeft();
            var pw = pageWidth();
            var visStart = sl;
            var visEnd = sl + pw;
            var container = document.getElementById('raedad-container');
            if (!container) return null;

            var SHOW_TEXT = 4;
            var walker = document.createTreeWalker(container, SHOW_TEXT, null);
            var firstNode = null, firstLeft = Infinity;
            var node;
            while ((node = walker.nextNode())) {
                if (!node.nodeValue || !node.nodeValue.trim()) continue;
                var r = document.createRange();
                r.selectNodeContents(node);
                var rect = r.getBoundingClientRect();
                // rect.left/right are viewport-relative; convert to absolute
                var absLeft = rect.left + sl;
                var absRight = rect.right + sl;
                // Check if any part of this text node is in the visible column
                if (absRight > visStart && absLeft < visEnd) {
                    if (absLeft < firstLeft) {
                        firstLeft = absLeft;
                        firstNode = node;
                    }
                    break; // tree walker is in document order, first hit is fine
                }
            }

            if (!firstNode) return null;

            // Binary search within the text node to find the exact
            // character offset where visibility starts.
            var lo = 0, hi = firstNode.length;
            while (hi - lo > 1) {
                var mid = Math.floor((lo + hi) / 2);
                var r = document.createRange();
                r.setStart(firstNode, mid);
                r.setEnd(firstNode, mid);
                var rects = r.getClientRects();
                if (rects.length === 0) { lo = mid; continue; }
                var absX = rects[0].left + sl;
                if (absX < visStart) lo = mid;
                else hi = mid;
            }

            var range = document.createRange();
            range.setStart(firstNode, lo);
            range.collapse(true);
            return range;
        }

        function getCenterRange() {
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            try {
                var range = document.caretRangeFromPoint(vw / 2, vh / 2);
                if (range && range.startContainer &&
                    container.contains(range.startContainer)) {
                    return range;
                }
            } catch(e) {}
            // Fallback to start-of-page anchor
            return getVisibleRange();
        }

        function updateAnchor() {
            if (currentMode !== 'paginated') return;
            try {
                var range = getCenterRange();
                if (range) currentAnchor = range;
            } catch(e) {}
        }

        function findPageForAnchor(anchor) {
            if (!anchor || !anchor.startContainer || !anchor.startContainer.parentNode) return -1;
            try {
                var rects = anchor.getClientRects();
                if (!rects || rects.length === 0) {
                    // collapsed range may not return rects; try expanding
                    var node = anchor.startContainer;
                    var off = anchor.startOffset;
                    if (node.nodeType === 3 && off < node.length) {
                        var r = document.createRange();
                        r.setStart(node, off);
                        r.setEnd(node, off + 1);
                        rects = r.getClientRects();
                    }
                }
                if (!rects || rects.length === 0) return -1;
                var rect = rects[0];
                var absoluteX = rect.left + getScrollLeft();
                var pw = pageWidth();
                return pw > 0 ? Math.floor(absoluteX / pw) : -1;
            } catch(e) { return -1; }
        }

        // --- Animation ---
        function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
        function easeOutQuad(t) { return 1 - (1 - t) * (1 - t); }

        function cancelAnimation() {
            if (animationId) { cancelAnimationFrame(animationId); animationId = null; }
        }

        var pageTurnLockTimer = null;
        // 500ms is a safety margin over the 250ms animateScroll duration —
        // long enough that overlapping flicks don't queue ghost page turns,
        // short enough that the lock doesn't suppress a legitimate next
        // input. Tuned by interactive feel; see git history before changing.
        var PAGE_TURN_LOCK_MS = 500;
        function lockPageTurn() {
            pageTurnLock = true;
            clearTimeout(pageTurnLockTimer);
            pageTurnLockTimer = setTimeout(unlockPageTurn, PAGE_TURN_LOCK_MS);
        }
        function unlockPageTurn() {
            pageTurnLock = false;
            clearTimeout(pageTurnLockTimer);
            pageTurnLockTimer = null;
        }

        function animateScroll(from, to, duration, easeFn, onComplete) {
            cancelAnimation();
            if (Math.abs(from - to) < 1) {
                setScrollLeft(to);
                if (onComplete) onComplete();
                return;
            }
            if (!easeFn) easeFn = easeOutCubic;
            var start = null;
            function step(ts) {
                if (!start) start = ts;
                var t = Math.min((ts - start) / duration, 1);
                setScrollLeft(from + (to - from) * easeFn(t));
                if (t < 1) {
                    animationId = requestAnimationFrame(step);
                } else {
                    animationId = null;
                    if (onComplete) onComplete();
                }
            }
            animationId = requestAnimationFrame(step);
        }

        // --- Pagination helpers ---
        // Each page is exactly one viewport width. The container is snapped
        // to a clean multiple of vw after layout so all calculations align.
        function totalPages() {
            var vw = window.innerWidth;
            if (vw <= 0) return 1;
            var sw = scroller.scrollWidth;
            return Math.max(1, Math.round(sw / vw));
        }

        function pageWidth() {
            return window.innerWidth || 1;
        }

        function getScrollLeft() { return scroller.scrollLeft; }
        function setScrollLeft(val) { scroller.scrollLeft = val; }
        function getMaxScroll() { return scroller.scrollWidth - scroller.clientWidth; }

        function reportPage() {
            var tp = totalPages();
            window.webkit.messageHandlers.pageHandler.postMessage({
                currentPage: currentPageIdx,
                totalPages: tp
            });
            updateAnchor();
        }

        function goToPage(page, animate) {
            var tp = totalPages();
            page = Math.max(0, Math.min(page, tp - 1));
            currentPageIdx = page;
            var target = page * pageWidth();
            var maxScroll = getMaxScroll();
            if (target > maxScroll) target = maxScroll;
            if (animate) {
                lockPageTurn();
                animateScroll(getScrollLeft(), target, 250, easeOutCubic, function() {
                    unlockPageTurn();
                    updateAnchor();
                });
            } else {
                cancelAnimation();
                setScrollLeft(target);
            }
            reportPage();
        }

        function nextPage() {
            if (pageTurnLock) return;
            if (currentPageIdx >= totalPages() - 1) {
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'next'});
            } else {
                goToPage(currentPageIdx + 1, true);
            }
        }

        function prevPage() {
            if (pageTurnLock) return;
            if (currentPageIdx <= 0) {
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'previous'});
            } else {
                goToPage(currentPageIdx - 1, true);
            }
        }

        function goToEnd(animate) {
            var maxScroll = getMaxScroll();
            if (maxScroll <= 0) { currentPageIdx = 0; reportPage(); return; }
            var pw = pageWidth();
            currentPageIdx = pw > 0 ? Math.round(maxScroll / pw) : 0;
            if (animate) {
                lockPageTurn();
                animateScroll(getScrollLeft(), maxScroll, 250, easeOutCubic, function() {
                    unlockPageTurn();
                    updateAnchor();
                });
            } else {
                cancelAnimation();
                setScrollLeft(maxScroll);
            }
            reportPage();
        }

        // --- Layout ---
        // Split into viewport dimensions (changes on every resize) and
        // column layout (only changes when width changes or columns grow).
        // This prevents text reflow on toolbar toggle (height-only change).

        function applyViewportCSS(vw, vh) {
            viewportStyle.textContent = [
                'html {',
                '  margin: 0 !important; padding: 0 !important; overflow: hidden !important;',
                '  width: ' + vw + 'px !important; height: ' + vh + 'px !important;',
                '}',
                'html body {',
                '  margin: 0 !important; padding: 0 !important; overflow: hidden !important;',
                '  width: ' + vw + 'px !important; height: ' + vh + 'px !important;',
                '  touch-action: none; -webkit-text-size-adjust: 100%;',
                '}',
                '#raedad-scroller {',
                '  position: fixed; top: 0; left: 0;',
                '  width: ' + vw + 'px; height: ' + vh + 'px;',
                '  overflow-x: hidden; overflow-y: hidden;',
                '  touch-action: none;',
                '  -ms-overflow-style: none;',
                '  scrollbar-width: none;',
                '}',
                '#raedad-scroller::-webkit-scrollbar { display: none; }'
            ].join('\\n');
        }

        function applyColumnCSS(contentHeight) {
            columnStyle.textContent = [
                '#raedad-container {',
                '  padding: ' + MARGIN_TB + 'px ' + MARGIN_LR + 'px;',
                '  width: max-content;',
                '  height: ' + contentHeight + 'px;',
                '  column-width: ' + cachedColWidth + 'px;',
                '  column-gap: ' + cachedColGap + 'px;',
                '  column-fill: auto;',
                '  overflow-wrap: break-word;',
                '  word-wrap: break-word;',
                '  widows: 2;',
                '  orphans: 2;',
                '  -webkit-line-box-contain: block glyphs replaced;',
                '}',
                '#raedad-container > * {',
                '  max-width: ' + cachedColWidth + 'px;',
                '  box-sizing: border-box;',
                '}',
                '#raedad-container pre {',
                '  white-space: pre-wrap;',
                '}',
                'img, svg, video, canvas, table {',
                '  max-width: 100%;',
                '  max-height: ' + (contentHeight - 20) + 'px;',
                '  object-fit: contain;',
                '  break-inside: avoid !important;',
                '  -webkit-column-break-inside: avoid !important;',
                '  page-break-inside: avoid !important;',
                '}'
            ].join('\\n');
            container.style.width = '';
        }

        // forceTwoUp: true / false = explicit override, null = auto.
        // In auto mode, two-up kicks in when the viewport is wider than tall.
        // (Swift collapses auto to false for iPhone before sending, so this
        // branch only fires on iPad / macOS / visionOS.)
        function resolveTwoUp() {
            if (forceTwoUp !== null) return forceTwoUp === true;
            var w = window.innerWidth;
            var h = window.innerHeight;
            return w > 0 && h > 0 && w > h;
        }

        function updateColumnMetrics(vw) {
            isTwoPage = resolveTwoUp();
            // Pick the margin pair that matches the resolved layout. On
            // rotation this re-runs and the active margins flip with the
            // column count, so layout stays internally consistent.
            var m = isTwoPage ? marginsTwoUp : marginsOneUp;
            MARGIN_TB = m.tb;
            MARGIN_LR = m.lr;
            cachedColGap = MARGIN_LR * 2;
            cachedColWidth = isTwoPage
                ? (vw - cachedColGap * 2) / 2
                : vw - cachedColGap;
        }

        function applyLayout() {
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            if (vw <= 0 || vh <= 0) return;

            updateColumnMetrics(vw);
            applyViewportCSS(vw, vh);
            applyColumnCSS(vh - MARGIN_TB * 2);
        }

        function appendVirtualColumnIfNeeded() {
            var existing = document.getElementById('raedad-virtual-col');
            if (existing) existing.remove();
            if (!isTwoPage) return;
            var colStep = cachedColWidth + cachedColGap;
            if (colStep <= 0) return;
            void container.offsetWidth; // force layout
            var numCols = Math.round(container.scrollWidth / colStep);
            if (numCols % 2 !== 0) {
                var vcol = document.createElement('div');
                vcol.id = 'raedad-virtual-col';
                vcol.style.breakBefore = 'column';
                vcol.innerHTML = '&#8203;';
                container.appendChild(vcol);
            }
        }

        // Snap container width to an exact multiple of viewport width
        // so that page-aligned scrolling has zero drift.
        function snapToPageBoundaries() {
            var vw = window.innerWidth;
            if (vw <= 0) return;
            void container.offsetWidth; // force layout
            var sw = scroller.scrollWidth;
            var numPages = Math.max(1, Math.round(sw / vw));
            container.style.width = (numPages * vw - MARGIN_LR * 2) + 'px';
        }

        function setTwoUp(value) {
            forceTwoUp = value;
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            doFullReflow(vw, vh, vh - MARGIN_TB * 2);
        }

        // --- Layout stability detection ---
        function waitForStableLayout(callback) {
            var lastWidth = -1, stableCount = 0;
            function check() {
                var sw = scroller.scrollWidth;
                if (sw === lastWidth) stableCount++;
                else { stableCount = 0; lastWidth = sw; }
                if (stableCount >= 5) callback();
                else requestAnimationFrame(check);
            }
            requestAnimationFrame(check);
        }

        // --- Resize handling ---
        // On every resize, do a full reflow so columns match the
        // actual viewport height. Center-anchor preservation keeps
        // the text in the middle of the screen stable; text at the
        // edges flows to adjacent pages.
        var resizeRAF = null;

        function handleResize() {
            if (currentMode !== 'paginated') return;
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            var contentHeight = vh - MARGIN_TB * 2;
            doFullReflow(vw, vh, contentHeight);
        }

        function doFullReflow(vw, vh, contentHeight) {
            var savedAnchor = currentAnchor;
            var fracFallback = totalPages() > 1 ? currentPageIdx / (totalPages() - 1) : 0;

            updateColumnMetrics(vw);

            applyViewportCSS(vw, vh);
            applyColumnCSS(contentHeight);
            appendVirtualColumnIfNeeded();
            snapToPageBoundaries();

            if (savedAnchor) {
                var page = findPageForAnchor(savedAnchor);
                if (page >= 0) {
                    page = Math.max(0, Math.min(page, totalPages() - 1));
                    currentPageIdx = page;
                    var target = page * pageWidth();
                    var maxScroll = getMaxScroll();
                    if (target > maxScroll) target = maxScroll;
                    cancelAnimation();
                    setScrollLeft(target);
                    window.webkit.messageHandlers.pageHandler.postMessage({
                        currentPage: currentPageIdx,
                        totalPages: totalPages()
                    });
                    return;
                }
            }

            var newTp = totalPages();
            var newPage = newTp > 1 ? Math.round(fracFallback * (newTp - 1)) : 0;
            goToPage(newPage);
        }

        function debouncedResize() {
            if (resizeRAF) cancelAnimationFrame(resizeRAF);
            resizeRAF = requestAnimationFrame(function() {
                resizeRAF = null;
                handleResize();
            });
        }

        // --- Keyboard ---
        function handleKeydown(e) {
            if (currentMode !== 'paginated') return;
            if (pageTurnLock) { e.preventDefault(); return; }
            if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
                e.preventDefault(); nextPage();
            } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
                e.preventDefault(); prevPage();
            } else if (e.key === ' ' && !e.shiftKey) {
                e.preventDefault(); nextPage();
            } else if (e.key === ' ' && e.shiftKey) {
                e.preventDefault(); prevPage();
            } else if (e.key === 'Home') {
                e.preventDefault(); goToPage(0, true);
            } else if (e.key === 'End') {
                e.preventDefault(); goToEnd(true);
            }
        }

        // --- Touch ---
        var touchStartX = 0, touchStartY = 0;
        var touchStartScroll = 0;
        var isDragging = false;
        var velocityTracker = [];
        var VELOCITY_THRESHOLD = 0.3;
        var SNAP_THRESHOLD = 0.25;

        function handleTouchStart(e) {
            if (currentMode !== 'paginated') return;
            if (e.touches.length !== 1) return;
            cancelAnimation();
            unlockPageTurn();
            scroller.style.transition = '';
            scroller.style.transform = '';
            touchStartX = e.touches[0].clientX;
            touchStartY = e.touches[0].clientY;
            touchStartScroll = getScrollLeft();
            isDragging = false;
            var now = performance.now();
            velocityTracker = [{x: touchStartX, t: now}];
        }

        function handleTouchMove(e) {
            if (currentMode !== 'paginated') return;
            if (e.touches.length !== 1) return;
            var cx = e.touches[0].clientX;
            var cy = e.touches[0].clientY;
            var dx = cx - touchStartX;
            var dy = cy - touchStartY;
            if (!isDragging) {
                if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
                if (Math.abs(dy) > Math.abs(dx)) return;
                isDragging = true;
            }
            e.preventDefault();
            var now = performance.now();
            velocityTracker.push({x: cx, t: now});
            while (velocityTracker.length > 1 && now - velocityTracker[0].t > 100) {
                velocityTracker.shift();
            }
            var targetScroll = touchStartScroll - dx;
            var maxScroll = getMaxScroll();
            if (targetScroll < 0) {
                setScrollLeft(0);
                scroller.style.transform = 'translate3d(' + (-targetScroll / 3) + 'px, 0, 0)';
            } else if (targetScroll > maxScroll) {
                setScrollLeft(maxScroll);
                scroller.style.transform = 'translate3d(' + (-(targetScroll - maxScroll) / 3) + 'px, 0, 0)';
            } else {
                scroller.style.transform = '';
                setScrollLeft(targetScroll);
            }
        }

        function handleTouchEnd(e) {
            if (currentMode !== 'paginated') return;
            if (e.changedTouches.length !== 1) return;
            var endX = e.changedTouches[0].clientX;
            var endY = e.changedTouches[0].clientY;
            var hadOverscroll = scroller.style.transform !== '' && scroller.style.transform !== 'none';
            if (hadOverscroll) {
                scroller.style.transition = 'transform 300ms cubic-bezier(0.25, 0.1, 0.25, 1)';
                scroller.style.transform = '';
                setTimeout(function() { scroller.style.transition = ''; }, 310);
            }
            // Detect taps: either isDragging was never set, or finger barely moved
            var dx = endX - touchStartX;
            var dy = endY - touchStartY;
            var isTap = !isDragging && (dx * dx + dy * dy < 625);
            if (isTap) {
                var w = window.innerWidth;
                if (endX < w / 3) { prevPage(); }
                else if (endX > w * 2 / 3) { nextPage(); }
                else { window.webkit.messageHandlers.pageHandler.postMessage({type: 'toggleChrome'}); }
                isDragging = false;
                return;
            }
            isDragging = false;

            // Velocity from 100ms window of touchmove events
            var velocity = 0;
            if (velocityTracker.length >= 2) {
                var last = velocityTracker[velocityTracker.length - 1];
                var first = velocityTracker[0];
                var dt = last.t - first.t;
                if (dt > 0) velocity = -(last.x - first.x) / dt;
            }

            var pw = pageWidth();
            var currentScroll = getScrollLeft();
            var targetPage;
            if (Math.abs(velocity) > VELOCITY_THRESHOLD) {
                targetPage = velocity > 0 ? currentPageIdx + 1 : currentPageIdx - 1;
            } else {
                var displacement = currentScroll - (currentPageIdx * pw);
                if (Math.abs(displacement) > pw * SNAP_THRESHOLD) {
                    targetPage = displacement > 0 ? currentPageIdx + 1 : currentPageIdx - 1;
                } else {
                    targetPage = currentPageIdx;
                }
            }
            var tp = totalPages();
            if (targetPage < 0) {
                goToPage(0, true);
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'previous'});
                return;
            }
            if (targetPage >= tp) {
                goToPage(tp - 1, true);
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'next'});
                return;
            }
            lockPageTurn();
            var targetScroll = targetPage * pw;
            var maxScroll = getMaxScroll();
            if (targetScroll > maxScroll) targetScroll = maxScroll;
            var velocityFactor = Math.min(1, Math.abs(velocity) / 2);
            var duration = Math.max(150, 300 * (1 - velocityFactor * 0.5));
            currentPageIdx = targetPage;
            animateScroll(currentScroll, targetScroll, duration, easeOutQuad, unlockPageTurn);
            reportPage();
        }

        // --- Wheel (smooth tracking + snap) ---
        // 120ms is "no wheel events for this many ms" — the cutoff for
        // "user finished the gesture, snap to nearest page". Empirically
        // matches trackpad inertia gaps; shorter values fire mid-gesture
        // and snap unexpectedly, longer values feel sluggish.
        var WHEEL_END_DEBOUNCE_MS = 120;
        // Once a wheel run looks like inertial momentum (3 successive events
        // with decreasing magnitude in the same direction within 200ms),
        // we ignore the rest so the page doesn't keep turning after the
        // user has stopped touching the trackpad.
        var MOMENTUM_LIMIT = 3;
        var wheelStartScroll = 0;
        var wheelAccum = 0;
        var wheelTimeout = null;
        var wheelVelocityTracker = [];
        var isWheelActive = false;
        var lastWheelTime = 0;
        var lastWheelDelta = 0;
        var lastWheelDir = 0;
        var momentumCount = 0;

        function handleWheel(e) {
            if (currentMode !== 'paginated') return;
            e.preventDefault();
            if (pageTurnLock && !isWheelActive) return;
            var now = performance.now();
            var delta = Math.abs(e.deltaX) >= Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
            var absDelta = Math.abs(delta);

            // Momentum detection — skip inertial events
            var dir = delta > 0 ? 1 : (delta < 0 ? -1 : 0);
            if (dir === lastWheelDir && absDelta <= lastWheelDelta && (now - lastWheelTime) < 200) {
                momentumCount++;
            } else if (dir !== lastWheelDir || (now - lastWheelTime) > 300) {
                momentumCount = 0;
            }
            lastWheelDelta = absDelta;
            lastWheelDir = dir;
            lastWheelTime = now;
            if (momentumCount >= MOMENTUM_LIMIT) return;

            // Begin tracking
            if (!isWheelActive) {
                isWheelActive = true;
                wheelStartScroll = getScrollLeft();
                wheelAccum = 0;
                wheelVelocityTracker = [];
                cancelAnimation();
                unlockPageTurn();
                scroller.style.transition = '';
                scroller.style.transform = '';
            }

            wheelAccum += delta;
            wheelVelocityTracker.push({d: delta, t: now});
            while (wheelVelocityTracker.length > 1 && now - wheelVelocityTracker[0].t > 100) {
                wheelVelocityTracker.shift();
            }

            // Apply scroll tracking
            var targetScroll = wheelStartScroll + wheelAccum;
            var maxScroll = getMaxScroll();
            if (targetScroll < 0) {
                setScrollLeft(0);
                scroller.style.transform = 'translate3d(' + (-targetScroll / 3) + 'px, 0, 0)';
            } else if (targetScroll > maxScroll) {
                setScrollLeft(maxScroll);
                scroller.style.transform = 'translate3d(' + (-(targetScroll - maxScroll) / 3) + 'px, 0, 0)';
            } else {
                scroller.style.transform = '';
                setScrollLeft(targetScroll);
            }

            // Snap after gesture ends (no wheel events for WHEEL_END_DEBOUNCE_MS)
            clearTimeout(wheelTimeout);
            wheelTimeout = setTimeout(wheelEnd, WHEEL_END_DEBOUNCE_MS);
        }

        function wheelEnd() {
            isWheelActive = false;
            var hadOverscroll = scroller.style.transform !== '' && scroller.style.transform !== 'none';
            if (hadOverscroll) {
                scroller.style.transition = 'transform 300ms cubic-bezier(0.25, 0.1, 0.25, 1)';
                scroller.style.transform = '';
                setTimeout(function() { scroller.style.transition = ''; }, 310);
            }

            // Velocity from recent events
            var velocity = 0;
            if (wheelVelocityTracker.length >= 2) {
                var last = wheelVelocityTracker[wheelVelocityTracker.length - 1];
                var first = wheelVelocityTracker[0];
                var dt = last.t - first.t;
                if (dt > 0) {
                    var totalDelta = 0;
                    for (var i = 0; i < wheelVelocityTracker.length; i++) totalDelta += wheelVelocityTracker[i].d;
                    velocity = totalDelta / dt;
                }
            }

            var pw = pageWidth();
            var currentScroll = getScrollLeft();
            var targetPage;
            if (Math.abs(velocity) > VELOCITY_THRESHOLD) {
                targetPage = velocity > 0 ? currentPageIdx + 1 : currentPageIdx - 1;
            } else {
                var displacement = currentScroll - (currentPageIdx * pw);
                if (Math.abs(displacement) > pw * SNAP_THRESHOLD) {
                    targetPage = displacement > 0 ? currentPageIdx + 1 : currentPageIdx - 1;
                } else {
                    targetPage = currentPageIdx;
                }
            }

            var tp = totalPages();
            if (targetPage < 0) targetPage = 0;
            if (targetPage >= tp) targetPage = tp - 1;
            lockPageTurn();
            var targetScroll = targetPage * pw;
            var maxScroll = getMaxScroll();
            if (targetScroll > maxScroll) targetScroll = maxScroll;
            var velocityFactor = Math.min(1, Math.abs(velocity) / 2);
            var duration = Math.max(150, 300 * (1 - velocityFactor * 0.5));
            currentPageIdx = targetPage;
            animateScroll(currentScroll, targetScroll, duration, easeOutQuad, unlockPageTurn);
            reportPage();
        }

        // --- Scroll mode helpers ---
        function scrollFraction() {
            var maxScroll = document.body.scrollHeight - window.innerHeight;
            if (maxScroll <= 0) return 0;
            return window.scrollY / maxScroll;
        }

        function reportScroll() {
            window.webkit.messageHandlers.pageHandler.postMessage({
                scrollFraction: scrollFraction()
            });
        }

        function restoreScroll(fraction) {
            var maxScroll = document.body.scrollHeight - window.innerHeight;
            if (maxScroll > 0) {
                window.scrollTo(0, fraction * maxScroll);
            }
        }

        var scrollTimer = null;
        function handleScroll() {
            if (scrollTimer) clearTimeout(scrollTimer);
            scrollTimer = setTimeout(reportScroll, 100);
        }

        // --- Init ---
        function initPaginated(options) {
            currentMode = 'paginated';
            // Both margin pairs are stored locally; updateColumnMetrics picks
            // one based on the resolved layout.
            if (options.marginsOneUp) {
                marginsOneUp = { tb: options.marginsOneUp.tb, lr: options.marginsOneUp.lr };
            }
            if (options.marginsTwoUp) {
                marginsTwoUp = { tb: options.marginsTwoUp.tb, lr: options.marginsTwoUp.lr };
            }
            // Backward-compat: a single pair fills both layouts.
            if (options.marginTB !== undefined) {
                marginsOneUp.tb = options.marginTB;
                marginsTwoUp.tb = options.marginTB;
            }
            if (options.marginLR !== undefined) {
                marginsOneUp.lr = options.marginLR;
                marginsTwoUp.lr = options.marginLR;
            }
            if (options.twoUp !== undefined) forceTwoUp = options.twoUp;

            // DOM setup: body > scroller > container > [content]
            scroller = document.createElement('div');
            scroller.id = 'raedad-scroller';
            container = document.createElement('div');
            container.id = 'raedad-container';
            while (document.body.firstChild) {
                container.appendChild(document.body.firstChild);
            }
            scroller.appendChild(container);
            document.body.appendChild(scroller);

            viewportStyle = document.createElement('style');
            viewportStyle.id = 'raedad-viewport';
            document.head.appendChild(viewportStyle);

            columnStyle = document.createElement('style');
            columnStyle.id = 'raedad-columns';
            document.head.appendChild(columnStyle);

            applyLayout();

            // Event listeners
            document.addEventListener('keydown', handleKeydown);
            document.addEventListener('touchstart', handleTouchStart, {passive: true});
            document.addEventListener('touchmove', handleTouchMove, {passive: false});
            document.addEventListener('touchend', handleTouchEnd, {passive: true});
            document.addEventListener('wheel', handleWheel, {passive: false});
            // Tap-to-toggle for scrolling mode (rendered markdown on iOS).
            // Paginated mode has its own touch handlers; this catches scrolling-mode
            // center taps that the paginated handler skips.
            var scrollTapStartX = 0, scrollTapStartY = 0;
            document.addEventListener('touchstart', function(e) {
                if (currentMode === 'paginated') return;
                if (e.touches.length === 1) {
                    scrollTapStartX = e.touches[0].clientX;
                    scrollTapStartY = e.touches[0].clientY;
                }
            }, true);

            // Mouse click zone detection for macOS (center = toggle chrome, sides = page turn).
            // Skip touch-originated mouseup events on iPad/iPhone — the touchend handler
            // already processes taps, and a synthesized mouseup would double-toggle.
            var lastTouchEndTime = 0;
            document.addEventListener('touchend', function(e) {
                lastTouchEndTime = performance.now();
                // In scrolling mode, detect center taps for chrome toggle
                if (currentMode !== 'paginated' && e.changedTouches.length === 1) {
                    var dx = e.changedTouches[0].clientX - scrollTapStartX;
                    var dy = e.changedTouches[0].clientY - scrollTapStartY;
                    if (dx * dx + dy * dy < 625) {
                        var x = e.changedTouches[0].clientX;
                        var w = window.innerWidth;
                        if (x >= w / 3 && x <= w * 2 / 3) {
                            window.webkit.messageHandlers.pageHandler.postMessage({type: 'toggleChrome'});
                        }
                    }
                }
            }, true);
            document.addEventListener('mouseup', function(e) {
                if (currentMode !== 'paginated') return;
                if (performance.now() - lastTouchEndTime < 500) return;
                var w = window.innerWidth;
                var x = e.clientX;
                if (x >= w / 3 && x <= w * 2 / 3) {
                    window.webkit.messageHandlers.pageHandler.postMessage({type: 'toggleChrome'});
                } else if (x < w / 3) {
                    prevPage();
                } else {
                    nextPage();
                }
            });
            window.addEventListener('resize', debouncedResize);

            // Initial layout and navigation
            waitForStableLayout(function() {
                appendVirtualColumnIfNeeded();
                snapToPageBoundaries();
                if (options.startAtEnd) {
                    goToEnd(false);
                } else if (options.fragment) {
                    var el = document.getElementById(options.fragment);
                    if (el) {
                        el.scrollIntoView();
                        // Snap to nearest page boundary
                        var pw = pageWidth();
                        if (pw > 0) {
                            currentPageIdx = Math.round(getScrollLeft() / pw);
                            goToPage(currentPageIdx);
                        }
                    } else {
                        reportPage();
                    }
                } else if (options.startFraction !== undefined && options.startFraction > 0) {
                    var tp = totalPages();
                    var page = tp > 1 ? Math.round(options.startFraction * (tp - 1)) : 0;
                    goToPage(page);
                } else {
                    reportPage();
                }
                document.documentElement.style.visibility = 'visible';
            });
        }

        function initScroll(options) {
            currentMode = 'scroll';
            window.addEventListener('scroll', handleScroll, {passive: true});

            requestAnimationFrame(function() {
                if (options.startFraction !== undefined && options.startFraction > 0) {
                    restoreScroll(options.startFraction);
                } else if (options.fragment) {
                    var el = document.getElementById(options.fragment);
                    if (el) el.scrollIntoView();
                }
                document.documentElement.style.visibility = 'visible';
                reportScroll();
            });
        }

        // --- Trackpad pan tracking ---
        var panStartScroll = 0;

        function panStart() {
            if (currentMode !== 'paginated') return;
            cancelAnimation();
            unlockPageTurn();
            scroller.style.transition = '';
            scroller.style.transform = '';
            panStartScroll = getScrollLeft();
        }

        function panMove(dx) {
            if (currentMode !== 'paginated') return;
            var targetScroll = panStartScroll - dx;
            var maxScroll = getMaxScroll();
            if (targetScroll < 0) {
                setScrollLeft(0);
                scroller.style.transform = 'translate3d(' + (-targetScroll / 3) + 'px, 0, 0)';
            } else if (targetScroll > maxScroll) {
                setScrollLeft(maxScroll);
                scroller.style.transform = 'translate3d(' + (-(targetScroll - maxScroll) / 3) + 'px, 0, 0)';
            } else {
                scroller.style.transform = '';
                setScrollLeft(targetScroll);
            }
        }

        function panEnd(velocityX) {
            if (currentMode !== 'paginated') return;
            var hadOverscroll = scroller.style.transform !== '' && scroller.style.transform !== 'none';
            if (hadOverscroll) {
                scroller.style.transition = 'transform 300ms cubic-bezier(0.25, 0.1, 0.25, 1)';
                scroller.style.transform = '';
                setTimeout(function() { scroller.style.transition = ''; }, 310);
            }
            var pw = pageWidth();
            var currentScroll = getScrollLeft();
            var targetPage;
            if (Math.abs(velocityX) > VELOCITY_THRESHOLD) {
                targetPage = velocityX < 0 ? currentPageIdx + 1 : currentPageIdx - 1;
            } else {
                var displacement = currentScroll - (currentPageIdx * pw);
                if (Math.abs(displacement) > pw * SNAP_THRESHOLD) {
                    targetPage = displacement > 0 ? currentPageIdx + 1 : currentPageIdx - 1;
                } else {
                    targetPage = currentPageIdx;
                }
            }
            var tp = totalPages();
            if (targetPage < 0) {
                goToPage(0, true);
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'previous'});
                return;
            }
            if (targetPage >= tp) {
                goToPage(tp - 1, true);
                window.webkit.messageHandlers.pageHandler.postMessage({boundary: 'next'});
                return;
            }
            lockPageTurn();
            var targetScroll = targetPage * pw;
            var maxScroll = getMaxScroll();
            if (targetScroll > maxScroll) targetScroll = maxScroll;
            var velocityFactor = Math.min(1, Math.abs(velocityX) / 2);
            var duration = Math.max(150, 300 * (1 - velocityFactor * 0.5));
            currentPageIdx = targetPage;
            animateScroll(currentScroll, targetScroll, duration, easeOutQuad, unlockPageTurn);
            reportPage();
        }

        // --- Public API ---
        window.raedad = {
            init: function(mode, options) {
                options = options || {};
                if (mode === 'paginated') initPaginated(options);
                else initScroll(options);
            },
            goToPage: function(page, animate) { goToPage(page, animate); },
            nextPage: function() { nextPage(); },
            prevPage: function() { prevPage(); },
            goToEnd: function(animate) { goToEnd(animate); },
            totalPages: function() { return totalPages(); },
            currentPage: function() { return currentPageIdx; },
            setTwoUp: function(value) { setTwoUp(value); },
            // Backward-compat: applies the same pair to both layouts.
            // New callers should prefer setMarginsBoth.
            setMargins: function(tb, lr) {
                marginsOneUp = { tb: tb, lr: lr };
                marginsTwoUp = { tb: tb, lr: lr };
                if (currentMode === 'paginated') { applyLayout(); appendVirtualColumnIfNeeded(); snapToPageBoundaries(); reportPage(); }
            },
            setMarginsBoth: function(oneTB, oneLR, twoTB, twoLR) {
                marginsOneUp = { tb: oneTB, lr: oneLR };
                marginsTwoUp = { tb: twoTB, lr: twoLR };
                if (currentMode === 'paginated') { applyLayout(); appendVirtualColumnIfNeeded(); snapToPageBoundaries(); reportPage(); }
            },
            panStart: function() { panStart(); },
            panMove: function(dx) { panMove(dx); },
            panEnd: function(velocityX) { panEnd(velocityX); },
            goToAnchor: function(id) {
                var el = document.getElementById(id);
                if (!el) return;
                if (currentMode === 'paginated') {
                    var rect = el.getBoundingClientRect();
                    var sl = getScrollLeft();
                    var absX = sl + rect.left;
                    var pw = pageWidth();
                    if (pw > 0) {
                        var page = Math.floor(absX / pw);
                        goToPage(page, true);
                    }
                } else {
                    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    setTimeout(reportScroll, 300);
                }
            },
            scrollFraction: function() { return scrollFraction(); },
            restoreScroll: function(f) { restoreScroll(f); },
            reportScroll: function() { reportScroll(); },
            mode: function() { return currentMode; }
        };
    })();
    """

    // MARK: - CSS injection (text reader)

    func injectCSS(into webView: WKWebView) {
        guard let css = pendingCSS else {
            if currentCSS != nil {
                let removeJS = "document.getElementById('raedad-custom-style')?.remove();"
                webView.evaluateJavaScript(removeJS)
                currentCSS = nil
            }
            return
        }
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
            var el = document.getElementById('raedad-custom-style');
            if (!el) {
                el = document.createElement('style');
                el.id = 'raedad-custom-style';
                document.head.appendChild(el);
            }
            el.textContent = '\(escaped)';
        })();
        """
        webView.evaluateJavaScript(js)
        currentCSS = pendingCSS
    }

    /// Applies a two-up spread override to the paginated web view (text reader only).
    func applyTwoUp(_ twoUp: Bool?, to webView: WKWebView) {
        guard paginated, !isEPub else { return }
        let jsValue: String
        if let value = twoUp {
            jsValue = value ? "true" : "false"
        } else {
            jsValue = "null"
        }
        webView.evaluateJavaScript("window.raedad?.setTwoUp(\(jsValue));")
    }

    // MARK: - Navigation

    func nextPage() {
        if isEPub {
            webView?.evaluateJavaScript("window.bridge?.next();")
        } else {
            webView?.evaluateJavaScript("window.raedad?.nextPage();")
        }
    }

    func previousPage() {
        if isEPub {
            webView?.evaluateJavaScript("window.bridge?.prev();")
        } else {
            webView?.evaluateJavaScript("window.raedad?.prevPage();")
        }
    }

    // MARK: - ePub bridge methods

    func bridgeGoTo(_ target: String) {
        let escaped = target
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.bridge?.goTo('\(escaped)');")
    }

    func bridgeGoToFraction(_ fraction: Double) {
        webView?.evaluateJavaScript("window.bridge?.goToFraction(\(fraction));")
    }

    func bridgeSetFlow(_ mode: String) {
        webView?.evaluateJavaScript("window.bridge?.setFlow('\(mode)');")
    }

    func bridgeSetStyles(_ css: String) {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        webView?.evaluateJavaScript("window.bridge?.setStyles(`\(escaped)`);")
    }

    func bridgeSetColumnCount(_ count: Int?) {
        let arg = count.map(String.init) ?? "'auto'"
        webView?.evaluateJavaScript("window.bridge?.setColumnCount(\(arg));")
    }

    func bridgeSetMargins(topBottom: Double, leftRight: Double) {
        webView?.evaluateJavaScript("window.bridge?.setMargins(\(Int(topBottom)), \(Int(leftRight)));")
    }

    func bridgeSetMarginsBoth(oneTB: Double, oneLR: Double, twoTB: Double, twoLR: Double) {
        webView?.evaluateJavaScript("window.bridge?.setMarginsBoth(\(Int(oneTB)), \(Int(oneLR)), \(Int(twoTB)), \(Int(twoLR)));")
    }

    func bridgeNextSection() {
        webView?.evaluateJavaScript("window.bridge?.nextSection();")
    }

    func bridgePreviousSection() {
        webView?.evaluateJavaScript("window.bridge?.prevSection();")
    }

    func bridgeSearch(_ query: String) {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        webView?.evaluateJavaScript("window.bridge?.search('\(escaped)');")
    }

    func bridgeClearSearch() {
        webView?.evaluateJavaScript("window.bridge?.clearSearch();")
    }

    func bridgeGoToSearchResult(_ cfi: String) {
        let escaped = cfi.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.bridge?.goToSearchResult('\(escaped)');")
    }

    func bridgeSetAnimated(_ enabled: Bool) {
        webView?.evaluateJavaScript("window.bridge?.setAnimated(\(enabled));")
    }

    func bridgeCaptureViewportAnchor() {
        webView?.evaluateJavaScript("window.bridge?.captureViewportAnchor();")
    }

    func bridgeStartReadAloud() {
        webView?.evaluateJavaScript("window.bridge?.startReadAloud();")
    }

    func bridgeHighlightReadAloud(start: Int, length: Int) {
        webView?.evaluateJavaScript("window.bridge?.highlightReadAloud(\(start), \(length));")
    }

    func bridgeClearReadAloud() {
        webView?.evaluateJavaScript("window.bridge?.clearReadAloud();")
    }

    func bridgeStopReadAloud() {
        webView?.evaluateJavaScript("window.bridge?.stopReadAloud();")
    }

    func bridgeAdvanceReadAloudSection() {
        webView?.evaluateJavaScript("window.bridge?.advanceReadAloudSection();")
    }

    func bridgeScrollToReadAloudOffset(_ offset: Int) {
        webView?.evaluateJavaScript("window.bridge?.scrollToReadAloudOffset(\(offset));")
    }

    func textReaderSetMargins(topBottom: Double, leftRight: Double) {
        webView?.evaluateJavaScript("window.raedad?.setMargins(\(topBottom), \(leftRight));")
    }

    func textReaderSetMarginsBoth(one: MarginSettings, two: MarginSettings) {
        let js = "window.raedad?.setMarginsBoth(\(one.topBottom), \(one.leftRight), \(two.topBottom), \(two.leftRight));"
        webView?.evaluateJavaScript(js)
    }

    func textReaderGoToPage(_ page: Int, animate: Bool = true) {
        webView?.evaluateJavaScript("window.raedad?.goToPage(\(page), \(animate));")
    }

    func textReaderGoToAnchor(_ id: String) {
        let escaped = id.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.raedad?.goToAnchor('\(escaped)');")
    }

    func bridgeOpenBook() {
        let bookURL = "\(epubScheme)://bundle/book.epub"
        webView?.evaluateJavaScript("window.bridge?.open('\(bookURL)');")
    }

    func bridgeInit(lastLocation: String? = nil) {
        if let cfi = lastLocation {
            let escaped = cfi
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.bridge?.init({ lastLocation: '\(escaped)' });")
        } else {
            webView?.evaluateJavaScript("window.bridge?.init({ showTextStart: true });")
        }
    }

    /// Opens the EPUB and applies all initial settings in a single chained async call.
    func bridgeOpenAndInit(flow: String, css: String,
                           oneTB: Double, oneLR: Double,
                           twoTB: Double, twoLR: Double,
                           maxColumnCount: Int?, lastLocation: String?) {
        webLog.info("bridgeOpenAndInit: flow=\(flow, privacy: .public), cols=\(String(describing: maxColumnCount), privacy: .public), loc=\(String(describing: lastLocation), privacy: .public)")
        let bookURL = "\(epubScheme)://bundle/book.epub"
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        // maxColumnCount: nil = 'auto' (foliate resolves from orientation and
        // re-resolves on resize), Int = force that fixed value.
        let colArg = maxColumnCount.map(String.init) ?? "'auto'"
        let colJS = "window.bridge.setColumnCount(\(colArg));"
        let marginJS = "window.bridge.setMarginsBoth(\(Int(oneTB)), \(Int(oneLR)), \(Int(twoTB)), \(Int(twoLR)));"
        let initJS: String
        if let cfi = lastLocation {
            let escapedCFI = cfi
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            initJS = "await window.bridge.init({ lastLocation: '\(escapedCFI)' });"
        } else {
            initJS = "await window.bridge.init({ showTextStart: true });"
        }
        let js = """
        (async () => {
            try {
                await window.bridge.open('\(bookURL)');
                window.bridge.setFlow('\(flow)');
                window.bridge.setStyles(`\(escapedCSS)`);
                \(marginJS)
                \(colJS)
                \(initJS)
            } catch(e) {
                window.webkit.messageHandlers.bridge.postMessage({type:'error', message:'openAndInit: '+e.message});
            }
        })();
        """
        webView?.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {}

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {}

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The WebContent process crashed (memory pressure, sandbox violation, etc.).
        // Reload the current page to recover rather than leaving a blank view.
        _ = MainActor.assumeIsolated {
            if let url = currentFileURL {
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if isEPub {
                // ePub mode: reader.html loaded, bridge.js will self-initialize
                // and post 'bridgeReady' when ready. We open the book at that point.
                #if os(macOS)
                DispatchQueue.main.async {
                    webView.window?.makeFirstResponder(webView)
                }
                #endif
            } else {
                // Text reader mode: inject the readerScript
                webView.evaluateJavaScript(readerScript)
                injectCSS(into: webView)

                let mode = paginated ? "paginated" : "scroll"
                var options: [String: Any] = [:]
                if let one = currentMarginsOneUp, let two = currentMarginsTwoUp {
                    options["marginsOneUp"] = ["tb": one.topBottom, "lr": one.leftRight]
                    options["marginsTwoUp"] = ["tb": two.topBottom, "lr": two.leftRight]
                }
                if let twoUp = currentTwoUp {
                    options["twoUp"] = twoUp
                }
                if startAtEnd {
                    options["startAtEnd"] = true
                    startAtEnd = false
                } else if let fragment = pendingFragment, !fragment.isEmpty {
                    options["fragment"] = fragment
                    pendingFragment = nil
                } else if let fraction = pendingScrollFraction, fraction > 0 {
                    options["startFraction"] = fraction
                    pendingScrollFraction = nil
                }

                if let jsonData = try? JSONSerialization.data(withJSONObject: options),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    webView.evaluateJavaScript("window.raedad.init('\(mode)', \(jsonString));")
                } else {
                    webView.evaluateJavaScript("window.raedad.init('\(mode)', {});")
                }

                #if os(macOS)
                DispatchQueue.main.async {
                    webView.window?.makeFirstResponder(webView)
                }
                #endif
            }
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
            } else if message.name == "pageHandler" {
                handlePageHandlerMessage(body)
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
            let event = RelocateEvent(from: body)
            onRelocate?(event)
            // Also forward fraction as scroll position for generic tracking
            if let fraction = event.fraction {
                onScrollPositionChange?(fraction)
            }
        case "load":
            break // Section loaded
        case "bookOpened":
            webLog.info("Book opened")
        case "externalLink":
            if let href = body["href"] as? String, let url = URL(string: href) {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
        case "flowChanged":
            #if os(iOS)
            if let flow = body["flow"] as? String {
                epubFlowMode = flow
            }
            #endif
        case "toggleChrome":
            onToggleChrome?()
        case "searchResult":
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
            let text = body["text"] as? String ?? ""
            let sectionIndex = body["sectionIndex"] as? Int ?? -1
            let startOffset = body["startOffset"] as? Int ?? 0
            onReadAloudSectionText?(text, sectionIndex, startOffset)
        case "readAloudSeek":
            let offset = body["offset"] as? Int ?? 0
            let sectionIndex = body["sectionIndex"] as? Int ?? -1
            onReadAloudSeek?(offset, sectionIndex)
        case "error":
            if let msg = body["message"] as? String {
                webLog.error("Bridge error: \(msg, privacy: .public)")
            }
        default:
            break
        }
    }

    private func handlePageHandlerMessage(_ body: [String: Any]) {
        if let type = body["type"] as? String, type == "toggleChrome" {
            onToggleChrome?()
        } else if let boundary = body["boundary"] as? String {
            let direction: BoundaryDirection = boundary == "next" ? .next : .previous
            onBoundaryReached?(direction)
        } else if let current = body["currentPage"] as? Int,
                  let total = body["totalPages"] as? Int {
            onPageInfo?(current, total)
            let fraction = total > 1 ? Double(current) / Double(total - 1) : 0
            onScrollPositionChange?(fraction)
        } else if let fraction = body["scrollFraction"] as? Double {
            onScrollPositionChange?(fraction)
        }
    }
}

#if os(iOS)
extension WebViewCoordinator: UIGestureRecognizerDelegate {}
#endif

