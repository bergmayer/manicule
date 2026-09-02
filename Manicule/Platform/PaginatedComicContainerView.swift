import SwiftUI

#if os(iOS)
import UIKit

/// iOS comic reader paginated view. The container/coordinator boilerplate
/// lives in PaginatedContainer; this file just wires the per-page view
/// controller and resolves the page-pair for the current reading direction.
struct PaginatedComicContainerView: View {
    let pages: [URL]
    @Binding var currentPage: Int
    let twoUp: Bool
    let readingDirection: ComicArchive.ReadingDirection
    var trimWhitespace: Bool = false
    let onToggleChrome: () -> Void

    var body: some View {
        PaginatedContainer<ComicPageZoomViewController>(
            pageCount: pages.count,
            currentPage: $currentPage,
            pageStep: twoUp ? 2 : 1,
            backgroundColor: .black,
            interPageSpacing: 2,
            supportsTrackpadPan: false,
            // Re-display the current page when twoUp / direction / trim
            // changes — existing VCs were rendered for the old layout.
            // Page count is included so the displayed page doesn't outlive
            // a swap to a smaller archive.
            layoutKey: AnyHashable([
                AnyHashable(twoUp),
                AnyHashable(readingDirection),
                AnyHashable(trimWhitespace),
                AnyHashable(pages.count)
            ]),
            onToggleChrome: onToggleChrome
        ) { index in
            guard index >= 0, index < pages.count else { return nil }
            if twoUp {
                let secondIndex = index + 1 < pages.count ? index + 1 : nil
                let leftURL: URL
                let rightURL: URL?
                if readingDirection == .leftToRight {
                    leftURL = pages[index]
                    rightURL = secondIndex.map { pages[$0] }
                } else {
                    leftURL = secondIndex.map { pages[$0] } ?? pages[index]
                    rightURL = secondIndex != nil ? pages[index] : nil
                }
                return ComicPageZoomViewController(
                    primaryImageURL: leftURL,
                    secondaryImageURL: rightURL,
                    pageIndex: index,
                    trimWhitespace: trimWhitespace
                )
            } else {
                return ComicPageZoomViewController(
                    primaryImageURL: pages[index],
                    secondaryImageURL: nil,
                    pageIndex: index,
                    trimWhitespace: trimWhitespace
                )
            }
        }
    }
}

/// View controller for a single comic page (or two-page spread) with pinch-to-zoom.
class ComicPageZoomViewController: UIViewController, UIScrollViewDelegate, PaginatedPageVC {
    let primaryImageURL: URL
    let secondaryImageURL: URL?
    let pageIndex: Int
    let trimWhitespace: Bool

    private var scrollView: UIScrollView!
    private var contentView: UIView!
    private var primaryImageView: UIImageView!
    private var secondaryImageView: UIImageView?
    private var imageLoadTask: Task<Void, Never>?
    private var didStartImageLoad = false

    init(primaryImageURL: URL, secondaryImageURL: URL?, pageIndex: Int, trimWhitespace: Bool = false) {
        self.primaryImageURL = primaryImageURL
        self.secondaryImageURL = secondaryImageURL
        self.pageIndex = pageIndex
        self.trimWhitespace = trimWhitespace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

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

        // Build an empty image stack immediately. Image I/O, decoding, and
        // optional Vision trimming happen off the main actor after layout gives
        // us an appropriate downsampling size.
        primaryImageView = UIImageView()
        primaryImageView.contentMode = .scaleAspectFit
        primaryImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(primaryImageView)

        if secondaryImageURL != nil {
            let secondaryImageView = UIImageView()
            self.secondaryImageView = secondaryImageView
            secondaryImageView.contentMode = .scaleAspectFit
            secondaryImageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(secondaryImageView)

            // Two-up: side by side, each taking half width
            NSLayoutConstraint.activate([
                primaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                primaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                primaryImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                primaryImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),

                secondaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                secondaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                secondaryImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                secondaryImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),
            ])
        } else {
            // Single page: fill content view
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
        // Ensure scroll view content resizes when the parent frame changes
        // (fixes black screen when UIPageViewController initially has zero frame)
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        startImageLoadIfNeeded()
    }

    private func startImageLoadIfNeeded() {
        guard !didStartImageLoad, view.bounds.width > 0, view.bounds.height > 0 else { return }
        didStartImageLoad = true
        let primaryURL = primaryImageURL
        let secondaryURL = secondaryImageURL
        let trim = trimWhitespace
        let displayPixels = max(view.bounds.width, view.bounds.height)
            * view.traitCollection.displayScale
        // Preserve useful pinch-zoom detail without decoding arbitrarily large
        // source bitmaps. 8192 also bounds a worst-case page near 256 MiB RGBA.
        let maxPixelSize = min(8_192, max(2_048, Int(displayPixels * 2.5)))

        imageLoadTask = Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                (
                    loadComicPageCGImage(
                        at: primaryURL, trim: trim, maxPixelSize: maxPixelSize),
                    secondaryURL.flatMap {
                        loadComicPageCGImage(at: $0, trim: trim, maxPixelSize: maxPixelSize)
                    }
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            if let primary = images.0 { self.primaryImageView.image = UIImage(cgImage: primary) }
            if let secondary = images.1 { self.secondaryImageView?.image = UIImage(cgImage: secondary) }
        }
    }

    deinit {
        imageLoadTask?.cancel()
    }


    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Enable panning when zoomed, disable at 1x to let UIPageViewController handle swipes
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
