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
    var scaleFactor: Double? = nil
    var highlightSelection: PDFSelection? = nil
    var onToggleChrome: (() -> Void)? = nil
    var onNextPage: (() -> Void)? = nil
    var onPreviousPage: (() -> Void)? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
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
        (nsView as? ReaderPDFView)?.onCenterClick = onToggleChrome
        context.coordinator.onToggleChrome = onToggleChrome
        let mode = desiredDisplayMode
        let direction: PDFDisplayDirection = paginated ? .horizontal : .vertical
        if nsView.displayMode != mode || nsView.displayDirection != direction {
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
            let currentIdx = pdfDocument.index(for: currentPage)
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
                let index = document.index(for: currentPage)
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
    var scaleFactor: Double? = nil
    var highlightSelection: PDFSelection? = nil
    var onToggleChrome: (() -> Void)? = nil
    var onNextPage: (() -> Void)? = nil
    var onPreviousPage: (() -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
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

        context.coordinator.onToggleChrome = onToggleChrome
        context.coordinator.onNextPage = onNextPage
        context.coordinator.onPreviousPage = onPreviousPage
        context.coordinator.observePageChanges(on: view)

        // Double-tap to toggle chrome (backup gesture)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // Single-tap zones: left 1/3 prev, right 1/3 next, center 1/3 toggle chrome
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        // For two-up mode (no UIPageViewController), add swipe gestures for page turning
        if paginated && twoUp {
            let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
            swipeLeft.direction = .left
            view.addGestureRecognizer(swipeLeft)

            let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
            swipeRight.direction = .right
            view.addGestureRecognizer(swipeRight)
        }

        return view
    }

    /// Only handles page navigation, zoom, and callback updates.
    /// Mode changes are handled by SwiftUI recreating the view via `.id()`.
    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.onToggleChrome = onToggleChrome
        context.coordinator.onNextPage = onNextPage
        context.coordinator.onPreviousPage = onPreviousPage

        if let scale = scaleFactor {
            uiView.autoScales = false
            uiView.scaleFactor = CGFloat(scale)
        }

        if let currentPage = uiView.currentPage {
            let currentIdx = pdfDocument.index(for: currentPage)
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
                let index = document.index(for: currentPage)
                // Defer to avoid "Modifying state during view update"
                DispatchQueue.main.async {
                    if self.parent.currentPageIndex != index {
                        self.parent.currentPageIndex = index
                    }
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            onToggleChrome?()
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

        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            if gesture.direction == .left {
                onNextPage?()
            } else if gesture.direction == .right {
                onPreviousPage?()
            }
        }

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}

#endif
