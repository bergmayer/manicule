import SwiftUI
import PDFKit

#if os(iOS)
import UIKit

/// iOS PDF reader paginated view. The container/coordinator boilerplate lives
/// in PaginatedContainer; this file just wires the per-page view controller.
struct PaginatedPDFContainerView: View {
    let pdfDocument: PDFDocument
    @Binding var currentPage: Int
    let twoUp: Bool
    var trimWhitespace: Bool = false
    let onToggleChrome: () -> Void

    var body: some View {
        PaginatedContainer<PDFPageSpreadViewController>(
            pageCount: pdfDocument.pageCount,
            currentPage: $currentPage,
            pageStep: twoUp ? 2 : 1,
            backgroundColor: .white,
            interPageSpacing: 4,
            supportsTrackpadPan: true,
            // Re-display the current page when twoUp or trim toggles —
            // existing VCs were rendered against the old mode.
            layoutKey: AnyHashable([twoUp, trimWhitespace]),
            onToggleChrome: onToggleChrome
        ) { index in
            let secondIndex = twoUp && index + 1 < pdfDocument.pageCount ? index + 1 : nil
            return PDFPageSpreadViewController(
                pdfDocument: pdfDocument,
                pageIndex: index,
                secondPageIndex: secondIndex,
                trimWhitespace: trimWhitespace
            )
        }
    }
}

/// View controller for a single PDF page (or two-page spread) with pinch-to-zoom.
class PDFPageSpreadViewController: UIViewController, UIScrollViewDelegate, PaginatedPageVC {
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
