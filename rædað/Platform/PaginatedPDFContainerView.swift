import SwiftUI
import PDFKit

#if os(iOS)
import UIKit

/// UIPageViewController-based container for paginated PDF reading on iOS.
/// Provides interactive finger-tracking swipe, tap zones, trackpad support,
/// and per-page pinch-to-zoom. Handles both single-page and two-up modes.
struct PaginatedPDFContainerView: UIViewControllerRepresentable {
    let pdfDocument: PDFDocument
    @Binding var currentPage: Int
    let twoUp: Bool
    var trimWhitespace: Bool = false
    let onToggleChrome: () -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 4]
        )
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = .white

        // Single tap for zone detection
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        pageVC.view.addGestureRecognizer(singleTap)

        // Trackpad pan for page turning
        let trackpadPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTrackpadPan(_:)))
        trackpadPan.allowedScrollTypesMask = .continuous
        trackpadPan.maximumNumberOfTouches = 0
        pageVC.view.addGestureRecognizer(trackpadPan)

        // Set initial page
        if let vc = context.coordinator.viewController(for: currentPage) {
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }

        return pageVC
    }

    func updateUIViewController(_ pageVC: UIPageViewController, context: Context) {
        let coord = context.coordinator
        let oldTwoUp = coord.twoUp
        let oldTrim = coord.trimWhitespace
        coord.pdfDocument = pdfDocument
        coord.twoUp = twoUp
        coord.trimWhitespace = trimWhitespace
        coord.onToggleChrome = onToggleChrome

        let displayedPage = coord.displayedPageIndex(from: pageVC)
        let modeChanged = oldTwoUp != twoUp || oldTrim != trimWhitespace

        if displayedPage != currentPage || modeChanged {
            if let vc = coord.viewController(for: currentPage) {
                let direction: UIPageViewController.NavigationDirection =
                    currentPage > (displayedPage ?? 0) ? .forward : .reverse
                pageVC.setViewControllers([vc], direction: direction, animated: false)
            }
        }

        coord.currentPage = currentPage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pdfDocument: pdfDocument,
            currentPage: $currentPage,
            twoUp: twoUp,
            trimWhitespace: trimWhitespace,
            onToggleChrome: onToggleChrome
        )
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var pdfDocument: PDFDocument
        var currentPage: Int
        private var currentPageBinding: Binding<Int>
        var twoUp: Bool
        var trimWhitespace: Bool
        var onToggleChrome: () -> Void
        private var trackpadTriggered = false
        private var lastTapTime: TimeInterval = 0

        init(pdfDocument: PDFDocument, currentPage: Binding<Int>, twoUp: Bool, trimWhitespace: Bool, onToggleChrome: @escaping () -> Void) {
            self.pdfDocument = pdfDocument
            self.currentPage = currentPage.wrappedValue
            self.currentPageBinding = currentPage
            self.twoUp = twoUp
            self.trimWhitespace = trimWhitespace
            self.onToggleChrome = onToggleChrome
        }

        private var pageCount: Int { pdfDocument.pageCount }
        private var pageStep: Int { twoUp ? 2 : 1 }

        func viewController(for pageIndex: Int) -> PDFPageSpreadViewController? {
            guard pageIndex >= 0, pageIndex < pageCount else { return nil }
            let secondIndex = twoUp && pageIndex + 1 < pageCount ? pageIndex + 1 : nil
            return PDFPageSpreadViewController(
                pdfDocument: pdfDocument,
                pageIndex: pageIndex,
                secondPageIndex: secondIndex,
                trimWhitespace: trimWhitespace
            )
        }

        func displayedPageIndex(from pageVC: UIPageViewController) -> Int? {
            guard let vc = pageVC.viewControllers?.first as? PDFPageSpreadViewController else { return nil }
            return vc.pageIndex
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PDFPageSpreadViewController else { return nil }
            let prevIndex = vc.pageIndex - pageStep
            guard prevIndex >= 0 else { return nil }
            return self.viewController(for: prevIndex)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PDFPageSpreadViewController else { return nil }
            let nextIndex = vc.pageIndex + pageStep
            guard nextIndex < pageCount else { return nil }
            return self.viewController(for: nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let vc = pageViewController.viewControllers?.first as? PDFPageSpreadViewController else { return }
            currentPage = vc.pageIndex
            currentPageBinding.wrappedValue = vc.pageIndex
        }

        // MARK: - Tap Zones

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            // Debounce: prevent a single trackpad click from firing twice
            let now = CACurrentMediaTime()
            guard now - lastTapTime > 0.2 else { return }
            lastTapTime = now
            let x = gesture.location(in: view).x
            let width = view.bounds.width
            if x < width / 3 {
                goToPrevious(in: view)
            } else if x > width * 2 / 3 {
                goToNext(in: view)
            } else {
                onToggleChrome()
            }
        }

        // MARK: - Trackpad Pan

        @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                trackpadTriggered = false
            case .changed:
                guard !trackpadTriggered else { return }
                let tx = gesture.translation(in: gesture.view).x
                if abs(tx) > 20 {
                    trackpadTriggered = true
                    if let view = gesture.view {
                        if tx < 0 { goToNext(in: view) } else { goToPrevious(in: view) }
                    }
                }
            default:
                break
            }
        }

        // MARK: - Programmatic Navigation (instant, no animation)

        private func goToNext(in view: UIView) {
            let nextIndex = currentPage + pageStep
            guard nextIndex < pageCount else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = self.viewController(for: nextIndex) else { return }
            currentPage = nextIndex
            currentPageBinding.wrappedValue = nextIndex
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }

        private func goToPrevious(in view: UIView) {
            let prevIndex = currentPage - pageStep
            guard prevIndex >= 0 else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = self.viewController(for: prevIndex) else { return }
            currentPage = prevIndex
            currentPageBinding.wrappedValue = prevIndex
            pageVC.setViewControllers([vc], direction: .reverse, animated: false)
        }

        private func findPageViewController(from view: UIView) -> UIPageViewController? {
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let pageVC = next as? UIPageViewController { return pageVC }
                responder = next
            }
            return nil
        }
    }
}

/// View controller for a single PDF page (or two-page spread) with pinch-to-zoom.
class PDFPageSpreadViewController: UIViewController, UIScrollViewDelegate {
    let pdfDocument: PDFDocument
    let pageIndex: Int
    let secondPageIndex: Int?
    let trimWhitespace: Bool

    private var scrollView: UIScrollView!
    private var contentView: UIView!
    private var primaryImageView: UIImageView!
    private var secondaryImageView: UIImageView?
    private var hasRendered = false

    init(pdfDocument: PDFDocument, pageIndex: Int, secondPageIndex: Int?, trimWhitespace: Bool = false) {
        self.pdfDocument = pdfDocument
        self.pageIndex = pageIndex
        self.secondPageIndex = secondPageIndex
        self.trimWhitespace = trimWhitespace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        scrollView = UIScrollView()
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isScrollEnabled = false // Disabled at 1x so UIPageViewController gets swipes
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        primaryImageView = UIImageView()
        primaryImageView.contentMode = .scaleAspectFit
        primaryImageView.backgroundColor = .white
        primaryImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(primaryImageView)

        if secondPageIndex != nil {
            let secondary = UIImageView()
            secondary.contentMode = .scaleAspectFit
            secondary.backgroundColor = .white
            secondary.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(secondary)
            secondaryImageView = secondary

            // Two-up: side by side, each taking half width with small gap
            NSLayoutConstraint.activate([
                primaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                primaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                primaryImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                primaryImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.498),

                secondary.topAnchor.constraint(equalTo: contentView.topAnchor),
                secondary.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                secondary.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                secondary.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.498),
            ])
        } else {
            NSLayoutConstraint.activate([
                primaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                primaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                primaryImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                primaryImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        // Content view matches scroll view size at 1x
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap to toggle zoom
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasRendered, view.bounds.width > 0 else { return }
        hasRendered = true
        renderPages()
    }

    private func renderPages() {
        let scale = view.window?.windowScene?.screen.scale ?? UITraitCollection.current.displayScale
        let availableSize = view.bounds.size

        if let page = pdfDocument.page(at: pageIndex) {
            let pageSize = pageImageSize(for: page, within: availableSize, isTwoUp: secondPageIndex != nil)
            let renderSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            primaryImageView.image = trimIfNeeded(page.thumbnail(of: renderSize, for: .mediaBox), key: "pdf-\(pageIndex)")
        }

        if let secondIndex = secondPageIndex, let page = pdfDocument.page(at: secondIndex) {
            let pageSize = pageImageSize(for: page, within: availableSize, isTwoUp: true)
            let renderSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            secondaryImageView?.image = trimIfNeeded(page.thumbnail(of: renderSize, for: .mediaBox), key: "pdf-\(secondIndex)")
        }
    }

    private func trimIfNeeded(_ image: UIImage, key: String) -> UIImage {
        guard trimWhitespace, let cgImage = image.cgImage else { return image }
        let trimmed = ContentTrimmer.shared.trimmed(cgImage, key: key)
        return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Calculates the display size for a single PDF page within the available area.
    private func pageImageSize(for page: PDFPage, within available: CGSize, isTwoUp: Bool) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        let maxWidth = isTwoUp ? available.width * 0.498 : available.width
        let maxHeight = available.height
        let scale = min(maxWidth / bounds.width, maxHeight / bounds.height)
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scrollView.isScrollEnabled = scale > 1.01
    }

    // MARK: - Double-tap zoom

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: contentView)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }
}
#endif
