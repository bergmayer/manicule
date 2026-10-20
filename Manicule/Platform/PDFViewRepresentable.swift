import SwiftUI
import PDFKit

#if os(macOS)

/// PDFView subclass that suppresses the initial selection/cursor box
/// and detects single clicks in the center zone to toggle chrome.
private class ReaderPDFView: PDFView {
    var onCenterClick: (() -> Void)?
    private var mouseDownLocation: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableFocusRingsRecursively(in: self)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let downLocation = mouseDownLocation else { return }
        let upLocation = convert(event.locationInWindow, from: nil)

        // Only fire for click-in-place (not drag/selection)
        let dx = abs(upLocation.x - downLocation.x)
        let dy = abs(upLocation.y - downLocation.y)
        guard dx < 5 && dy < 5 else { return }

        // Only fire for center third
        let thirdWidth = bounds.width / 3
        guard upLocation.x >= thirdWidth && upLocation.x <= thirdWidth * 2 else { return }

        onCenterClick?()
        mouseDownLocation = nil
    }

    private func disableFocusRingsRecursively(in view: NSView) {
        view.focusRingType = .none
        for subview in view.subviews {
            disableFocusRingsRecursively(in: subview)
        }
    }
}

/// macOS wrapper for PDFView in SwiftUI.
struct PDFViewRepresentable: NSViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var currentPageIndex: Int
    var paginated: Bool = true
    var twoUp: Bool = false
    var coverOnRight: Bool = false
    var scaleFactor: Double? = nil
    var highlightSelection: PDFSelection? = nil
    var onToggleChrome: (() -> Void)? = nil
    var onNextPage: (() -> Void)? = nil
    var onPreviousPage: (() -> Void)? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.displaysAsBook = coverOnRight && twoUp
        view.document = pdfDocument
        view.autoScales = true
        view.displayMode = desiredDisplayMode
        view.displayDirection = paginated ? .horizontal : .vertical
        view.isInMarkupMode = false
        view.clearSelection()
        view.onCenterClick = onToggleChrome
        context.coordinator.onToggleChrome = onToggleChrome
        context.coordinator.observePageChanges(on: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.parent = self
        (nsView as? ReaderPDFView)?.onCenterClick = onToggleChrome
        context.coordinator.onToggleChrome = onToggleChrome
        let pairingChanged = nsView.displaysAsBook != (coverOnRight && twoUp)
        if pairingChanged { nsView.displaysAsBook = coverOnRight && twoUp }
        let mode = desiredDisplayMode
        let direction: PDFDisplayDirection = paginated ? .horizontal : .vertical
        if nsView.displayMode != mode || nsView.displayDirection != direction || pairingChanged {
            nsView.displayMode = mode
            nsView.displayDirection = direction
            // Re-enable autoScales after mode change so the page fits the view
            if scaleFactor == nil {
                nsView.autoScales = true
            }
            nsView.layoutDocumentView()
        }
        if let scale = scaleFactor {
            nsView.autoScales = false
            nsView.scaleFactor = CGFloat(scale)
        }
        if let currentPage = nsView.currentPage {
            let currentIdx = PageNavigation.normalizedStart(
                current: pdfDocument.index(for: currentPage), pageCount: pdfDocument.pageCount,
                twoUp: paginated && twoUp, coverOnRight: coverOnRight)
            if currentIdx != currentPageIndex,
               let targetPage = pdfDocument.page(at: currentPageIndex) {
                nsView.go(to: targetPage)
            }
        }

        if let selection = highlightSelection {
            selection.color = .yellow
            nsView.setCurrentSelection(selection, animate: true)
            nsView.scrollSelectionToVisible(nil)
        } else {
            nsView.clearSelection()
        }
    }

    private var desiredDisplayMode: PDFDisplayMode {
        if paginated {
            return twoUp ? .twoUp : .singlePage
        }
        return .singlePageContinuous
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: PDFViewRepresentable
        var onToggleChrome: (() -> Void)?
        private var observation: Any?

        init(_ parent: PDFViewRepresentable) {
            self.parent = parent
        }

        func observePageChanges(on pdfView: PDFView) {
            observation = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let pdfView = notification.object as? PDFView,
                      let currentPage = pdfView.currentPage,
                      let document = pdfView.document else { return }
                let index = PageNavigation.normalizedStart(
                    current: document.index(for: currentPage), pageCount: document.pageCount,
                    twoUp: self.parent.paginated && self.parent.twoUp, coverOnRight: self.parent.coverOnRight)
                // Defer to avoid "Modifying state during view update"
                DispatchQueue.main.async {
                    if self.parent.currentPageIndex != index {
                        self.parent.currentPageIndex = index
                    }
                }
            }
        }

        // Center-click is now handled by ReaderPDFView.mouseUp(with:)

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}

#else

/// Keeps PDFKit's native pinch elasticity, with zoom limits relative to page fit.
final class TouchReaderPDFView: PDFView {
    private var fittedScale: CGFloat = 0
    private var updatingLimits = false
    private var requestedZoom: Double?
    private var appliedZoom: Double?
    var usesExternalPaging = false
    var zoomDoubleTap: UITapGestureRecognizer?
    private let configuredTaps = NSHashTable<UITapGestureRecognizer>.weakObjects()

    override var accessibilityValue: String? {
        get {
            let fit = scaleFactorForSizeToFit
            guard fit > 0 else { return super.accessibilityValue }
            return "Zoom \(Int((scaleFactor / fit * 100).rounded()))%"
        }
        set { super.accessibilityValue = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateZoomLimits()
        if let zoomDoubleTap { prioritizeZoomGesture(in: self, over: zoomDoubleTap) }
        updatePagingScrollState()
    }

    private func prioritizeZoomGesture(in view: UIView, over zoomTap: UITapGestureRecognizer) {
        for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? [] {
            guard tap !== zoomTap, tap.numberOfTapsRequired == 2,
                  tap.numberOfTouchesRequired == 1, !configuredTaps.contains(tap) else { continue }
            tap.require(toFail: zoomTap)
            configuredTaps.add(tap)
        }
        for child in view.subviews { prioritizeZoomGesture(in: child, over: zoomTap) }
    }

    func updateZoomLimits() {
        guard !updatingLimits, bounds.width > 0, bounds.height > 0 else { return }
        let fit = scaleFactorForSizeToFit
        guard fit.isFinite, fit > 0 else { return }
        updatingLimits = true
        defer { updatingLimits = false }
        let oldFit = fittedScale
        let relativeScale = oldFit > 0 ? scaleFactor / oldFit : 1
        fittedScale = fit
        // PDFKit applies these limits to its zooming scroll views, retaining
        // the native rubber-band gesture below the minimum.
        let minimum = fit * 0.95
        let maximum = fit * 5
        if abs(minScaleFactor - minimum) > 0.0001 { minScaleFactor = minimum }
        if abs(maxScaleFactor - maximum) > 0.0001 { maxScaleFactor = maximum }
        if oldFit == 0 || abs(oldFit - fit) > 0.001 {
            scaleFactor = fit * min(5, max(0.95, relativeScale))
        }
        applyPendingZoom()
    }

    /// At page fit the outer page controller owns drags; zoomed pages pan inside PDFKit.
    func updatePagingScrollState() {
        guard usesExternalPaging else { return }
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        setScrolling(in: self, enabled: scaleFactor > fit * 1.05)
    }

    private func setScrolling(in view: UIView, enabled: Bool) {
        if let scroll = view as? UIScrollView, scroll.isScrollEnabled != enabled {
            scroll.isScrollEnabled = enabled
        }
        for child in view.subviews { setScrolling(in: child, enabled: enabled) }
    }

    func applyRequestedZoom(_ zoom: Double?) {
        requestedZoom = zoom
        updateZoomLimits()
        applyPendingZoom()
    }

    private func applyPendingZoom() {
        guard requestedZoom != appliedZoom, fittedScale > 0 else { return }
        appliedZoom = requestedZoom
        if let zoom = requestedZoom {
            scaleFactor = fittedScale * CGFloat(min(5, max(0.95, zoom)))
        }
    }

    func toggleZoom() {
        updateZoomLimits()
        guard fittedScale > 0 else { return }
        let target = scaleFactor > fittedScale * 1.05 ? fittedScale : fittedScale * 2.5
        UIView.animate(withDuration: 0.25) { self.scaleFactor = target }
    }
}

/// iOS/iPadOS wrapper for PDFView in SwiftUI.
///
/// IMPORTANT: `usePageViewController(true)` and `displayMode = .twoUp` are mutually exclusive.
/// When UIPageViewController is active, displayMode is ignored (always single-page).
/// Therefore this view is designed for one-time setup in `makeUIView` — mode changes are
/// handled by SwiftUI recreating the view via `.id()` in the parent.
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var currentPageIndex: Int
    var paginated: Bool = true
    var twoUp: Bool = false
    var coverOnRight: Bool = false
    var scaleFactor: Double? = nil
    var highlightSelection: PDFSelection? = nil
    var onToggleChrome: (() -> Void)? = nil
    var onNextPage: (() -> Void)? = nil
    var onPreviousPage: (() -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        makePDFView(coordinator: context.coordinator)
    }

    func makePDFView(coordinator: Coordinator) -> TouchReaderPDFView {
        let view = TouchReaderPDFView()
        view.accessibilityIdentifier = "pdf-reader"
        view.usesExternalPaging = paginated && twoUp
        view.displaysAsBook = coverOnRight && twoUp
        view.document = pdfDocument

        if paginated && !twoUp {
            // Single-page with native swipe via UIPageViewController.
            // usePageViewController ignores displayMode, so we don't set it.
            view.displayDirection = .horizontal
            view.usePageViewController(true, withViewOptions: nil)
        } else if paginated && twoUp {
            // Two-up spread. Cannot use usePageViewController (it ignores displayMode).
            view.displayMode = .twoUp
            view.displayDirection = .horizontal
        } else {
            // Scrolling continuous
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
        }

        view.autoScales = true
        view.clearSelection()

        // Navigate to saved page position
        if let page = pdfDocument.page(at: currentPageIndex) {
            view.go(to: page)
        }

        coordinator.onToggleChrome = onToggleChrome
        coordinator.onNextPage = onNextPage
        coordinator.onPreviousPage = onPreviousPage
        coordinator.observePageChanges(on: view)

        // Double-tap toggles zoom; single-tap retains the page/chrome zones.
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.zoomDoubleTap = doubleTap
        view.addGestureRecognizer(doubleTap)

        // Single-tap zones: left 1/3 prev, right 1/3 next, center 1/3 toggle chrome
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        return view
    }

    /// Only handles page navigation, zoom, and callback updates.
    /// Mode changes are handled by SwiftUI recreating the view via `.id()`.
    func updateUIView(_ uiView: PDFView, context: Context) {
        updatePDFView(uiView, coordinator: context.coordinator)
    }

    func updatePDFView(_ uiView: PDFView, coordinator: Coordinator) {
        if uiView.displaysAsBook != (coverOnRight && twoUp) {
            uiView.displaysAsBook = coverOnRight && twoUp
        }
        coordinator.parent = self
        coordinator.onToggleChrome = onToggleChrome
        coordinator.onNextPage = onNextPage
        coordinator.onPreviousPage = onPreviousPage

        (uiView as? TouchReaderPDFView)?.applyRequestedZoom(scaleFactor)

        if let currentPage = uiView.currentPage {
            // PDFKit can report either page of the visible spread while panning.
            // Navigating back to its first page would reset the user's zoom.
            let currentIdx = PageNavigation.normalizedStart(
                current: pdfDocument.index(for: currentPage), pageCount: pdfDocument.pageCount,
                twoUp: paginated && twoUp, coverOnRight: coverOnRight)
            if currentIdx != currentPageIndex,
               let targetPage = pdfDocument.page(at: currentPageIndex) {
                uiView.go(to: targetPage)
            }
        }

        if let selection = highlightSelection {
            selection.color = .yellow
            uiView.setCurrentSelection(selection, animate: true)
            uiView.scrollSelectionToVisible(nil)
        } else {
            uiView.clearSelection()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: PDFViewRepresentable
        var onToggleChrome: (() -> Void)?
        var onNextPage: (() -> Void)?
        var onPreviousPage: (() -> Void)?
        private var observation: Any?
        private var scaleObservation: Any?

        init(_ parent: PDFViewRepresentable) {
            self.parent = parent
        }

        func observePageChanges(on pdfView: PDFView) {
            scaleObservation = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: pdfView, queue: .main
            ) { notification in
                (notification.object as? TouchReaderPDFView)?.updatePagingScrollState()
            }
            observation = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let pdfView = notification.object as? PDFView,
                      let currentPage = pdfView.currentPage,
                      let document = pdfView.document else { return }
                (pdfView as? TouchReaderPDFView)?.setNeedsLayout()
                let index = PageNavigation.normalizedStart(
                    current: document.index(for: currentPage), pageCount: document.pageCount,
                    twoUp: self.parent.paginated && self.parent.twoUp, coverOnRight: self.parent.coverOnRight)
                // Defer to avoid "Modifying state during view update"
                DispatchQueue.main.async {
                    if self.parent.currentPageIndex != index {
                        self.parent.currentPageIndex = index
                    }
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            (gesture.view as? TouchReaderPDFView)?.toggleZoom()
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            if location.x < width / 3 {
                onPreviousPage?()
            } else if location.x > width * 2 / 3 {
                onNextPage?()
            } else {
                onToggleChrome?()
            }
        }

        deinit {
            if let scaleObservation { NotificationCenter.default.removeObserver(scaleObservation) }
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}

#endif
