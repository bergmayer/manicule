import SwiftUI

/// Zoomable vertical comic strip using platform-native scroll views.
/// Supports pinch-to-zoom, double-tap/click zoom toggle, pan when zoomed,
/// and vertical scrolling through all pages.
struct ZoomableComicStripView: View {
    let pages: [URL]
    let containerSize: CGSize
    var trimWhitespace: Bool = false
    let onTap: () -> Void
    @Binding var currentPage: Int
    @Binding var zoomScale: Double

    var body: some View {
        #if os(iOS)
        ZoomableComicStripView_iOS(
            pages: pages, containerSize: containerSize, trimWhitespace: trimWhitespace, onTap: onTap,
            currentPage: $currentPage, zoomScale: $zoomScale
        )
        #elseif os(macOS)
        ZoomableComicStripView_macOS(
            pages: pages, containerSize: containerSize, trimWhitespace: trimWhitespace, onTap: onTap,
            currentPage: $currentPage, zoomScale: $zoomScale
        )
        #endif
    }
}

// MARK: - iOS Implementation

#if os(iOS)

/// UIScrollView subclass that triggers initial page layout once bounds are available.
private class ComicStripUIScrollView: UIScrollView {
    weak var coordinator: ZoomableComicStripView_iOS.Coordinator?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let c = coordinator, c.imageViews.isEmpty, !c.pages.isEmpty, bounds.width > 0 else { return }
        c.layoutPages(in: self, width: bounds.width)
    }
}

private struct ZoomableComicStripView_iOS: UIViewRepresentable {
    let pages: [URL]
    let containerSize: CGSize
    var trimWhitespace: Bool = false
    let onTap: () -> Void
    @Binding var currentPage: Int
    @Binding var zoomScale: Double

    func makeUIView(context: Context) -> ComicStripUIScrollView {
        let sv = ComicStripUIScrollView()
        sv.delegate = context.coordinator
        sv.coordinator = context.coordinator
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 5.0
        sv.bouncesZoom = true
        sv.showsVerticalScrollIndicator = true
        sv.showsHorizontalScrollIndicator = false
        sv.backgroundColor = .clear

        let container = UIView()
        sv.addSubview(container)
        context.coordinator.containerView = container
        context.coordinator.scrollView = sv

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        sv.addGestureRecognizer(singleTap)

        return sv
    }

    func updateUIView(_ sv: ComicStripUIScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.trimWhitespace = trimWhitespace

        // Use containerSize from parent GeometryReader — reliable even when
        // the scroll view's own bounds are still 0 on the first layout pass.
        let width = containerSize.width
        guard width > 0 else { return }

        // Re-layout if width changed or pages changed
        if c.layoutWidth != width || c.imageViews.count != pages.count {
            c.pages = pages
            c.layoutPages(in: sv, width: width)
        }

        // Scroll to page if changed externally
        if currentPage != c.lastTrackedPage, currentPage < c.pageOffsets.count {
            c.lastTrackedPage = currentPage
            let yOffset = c.pageOffsets[currentPage] * sv.zoomScale
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: yOffset), animated: true)
        }

        // Sync zoom from external changes (e.g. Cmd+/-)
        let target = CGFloat(zoomScale)
        if abs(sv.zoomScale - target) > 0.01 {
            sv.setZoomScale(target, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage, zoomScale: $zoomScale, trimWhitespace: trimWhitespace, onTap: onTap)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var currentPage: Binding<Int>
        var zoomScale: Binding<Double>
        var trimWhitespace: Bool
        var onTap: () -> Void
        var containerView: UIView?
        weak var scrollView: UIScrollView?
        var pages: [URL] = []
        var layoutWidth: CGFloat = 0
        var imageViews: [UIImageView] = []
        var pageOffsets: [CGFloat] = []
        var lastTrackedPage: Int = 0

        init(currentPage: Binding<Int>, zoomScale: Binding<Double>, trimWhitespace: Bool, onTap: @escaping () -> Void) {
            self.currentPage = currentPage
            self.zoomScale = zoomScale
            self.trimWhitespace = trimWhitespace
            self.onTap = onTap
        }

        func layoutPages(in sv: UIScrollView, width: CGFloat) {
            guard let container = containerView else { return }
            layoutWidth = width

            container.subviews.forEach { $0.removeFromSuperview() }
            imageViews.removeAll()
            pageOffsets.removeAll()

            var y: CGFloat = 0
            let spacing: CGFloat = 4

            for url in pages {
                let imgSize = imageDimensions(at: url) ?? CGSize(width: width, height: width * 1.4)
                let ratio = imgSize.height / imgSize.width
                let h = width * ratio

                let iv = UIImageView()
                iv.contentMode = .scaleAspectFit
                iv.clipsToBounds = true
                iv.backgroundColor = .black
                iv.frame = CGRect(x: 0, y: y, width: width, height: h)
                container.addSubview(iv)
                imageViews.append(iv)
                pageOffsets.append(y)

                y += h + spacing
            }

            let totalH = max(0, y - spacing)
            container.frame = CGRect(x: 0, y: 0, width: width, height: totalH)
            sv.contentSize = CGSize(width: width, height: totalH)
            sv.zoomScale = CGFloat(zoomScale.wrappedValue)

            loadVisibleImages()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            containerView
        }

        func scrollViewDidZoom(_ sv: UIScrollView) {
            let scale = Double(sv.zoomScale)
            if abs(scale - zoomScale.wrappedValue) > 0.01 {
                zoomScale.wrappedValue = scale
            }
        }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            loadVisibleImages()
            let page = calculateVisiblePage(in: sv)
            if page != currentPage.wrappedValue {
                currentPage.wrappedValue = page
                lastTrackedPage = page
            }
        }

        private func calculateVisiblePage(in sv: UIScrollView) -> Int {
            let y = sv.contentOffset.y / max(sv.zoomScale, 1)
            for i in (0..<pageOffsets.count).reversed() {
                if y >= pageOffsets[i] - 50 {
                    return min(i, pages.count - 1)
                }
            }
            return 0
        }

        func loadVisibleImages() {
            guard let sv = scrollView else { return }
            let scale = max(sv.zoomScale, 1)
            let visibleY = sv.contentOffset.y / scale
            let visibleH = sv.bounds.height / scale
            let buffer: CGFloat = 500

            for (i, iv) in imageViews.enumerated() {
                let top = iv.frame.minY
                let bottom = iv.frame.maxY
                if bottom >= visibleY - buffer && top <= visibleY + visibleH + buffer {
                    if iv.image == nil {
                        iv.image = loadComicImage(at: pages[i], trim: trimWhitespace)
                    }
                } else {
                    iv.image = nil
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1.0, animated: true)
            } else {
                let pt = gesture.location(in: containerView)
                let size = CGSize(
                    width: sv.bounds.width / 2.5,
                    height: sv.bounds.height / 2.5
                )
                sv.zoom(to: CGRect(
                    x: pt.x - size.width / 2,
                    y: pt.y - size.height / 2,
                    width: size.width, height: size.height
                ), animated: true)
            }
        }

        @objc func handleTap() {
            onTap()
        }
    }
}
#endif

// MARK: - macOS Implementation

#if os(macOS)
import AppKit

/// NSScrollView subclass that triggers initial page layout once bounds are available.
private class ComicStripScrollView: NSScrollView {
    weak var coordinator: ZoomableComicStripView_macOS.Coordinator?

    override func layout() {
        super.layout()
        guard let c = coordinator, c.imageViews.isEmpty, !c.pages.isEmpty else { return }
        let w = contentView.bounds.width
        if w > 0 {
            c.layoutPages(in: self, width: w)
        }
    }
}

private struct ZoomableComicStripView_macOS: NSViewRepresentable {
    let pages: [URL]
    let containerSize: CGSize
    var trimWhitespace: Bool = false
    let onTap: () -> Void
    @Binding var currentPage: Int
    @Binding var zoomScale: Double

    func makeNSView(context: Context) -> ComicStripScrollView {
        let sv = ComicStripScrollView()
        sv.coordinator = context.coordinator
        sv.allowsMagnification = true
        sv.minMagnification = 1.0
        sv.maxMagnification = 5.0
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.backgroundColor = .clear

        let container = FlippedNSView()
        sv.documentView = container
        context.coordinator.containerView = container
        context.coordinator.scrollView = sv

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        container.addGestureRecognizer(doubleClick)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick)
        )
        click.numberOfClicksRequired = 1
        container.addGestureRecognizer(click)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: sv
        )

        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView
        )

        return sv
    }

    func updateNSView(_ sv: ComicStripScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.trimWhitespace = trimWhitespace

        // Use containerSize from parent GeometryReader — reliable even when
        // the scroll view's own bounds are still 0 on the first layout pass.
        let width = containerSize.width
        guard width > 0 else { return }

        // Re-layout if width changed or pages changed
        if c.layoutWidth != width || c.imageViews.count != pages.count {
            c.pages = pages
            c.layoutPages(in: sv, width: width)
        }

        // Scroll to page if changed externally
        if currentPage != c.lastTrackedPage, currentPage < c.pageOffsets.count {
            c.lastTrackedPage = currentPage
            let yOffset = c.pageOffsets[currentPage]
            sv.contentView.scroll(to: NSPoint(x: 0, y: yOffset))
            sv.reflectScrolledClipView(sv.contentView)
        }

        // Sync zoom from external changes (e.g. Cmd+/-)
        let target = CGFloat(zoomScale)
        if abs(sv.magnification - target) > 0.01 {
            sv.animator().magnification = target
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage, zoomScale: $zoomScale, trimWhitespace: trimWhitespace, onTap: onTap)
    }

    class Coordinator: NSObject {
        var currentPage: Binding<Int>
        var zoomScale: Binding<Double>
        var trimWhitespace: Bool
        var onTap: () -> Void
        var containerView: NSView?
        weak var scrollView: NSScrollView?
        var pages: [URL] = []
        var layoutWidth: CGFloat = 0
        var imageViews: [NSImageView] = []
        var pageOffsets: [CGFloat] = []
        var lastTrackedPage: Int = 0
        private var pendingSingleClick: DispatchWorkItem?

        init(currentPage: Binding<Int>, zoomScale: Binding<Double>, trimWhitespace: Bool, onTap: @escaping () -> Void) {
            self.currentPage = currentPage
            self.zoomScale = zoomScale
            self.trimWhitespace = trimWhitespace
            self.onTap = onTap
        }

        func layoutPages(in sv: NSScrollView, width: CGFloat) {
            guard let container = containerView else { return }
            layoutWidth = width

            container.subviews.forEach { $0.removeFromSuperview() }
            imageViews.removeAll()
            pageOffsets.removeAll()

            var y: CGFloat = 0
            let spacing: CGFloat = 4

            for url in pages {
                let imgSize = imageDimensions(at: url) ?? CGSize(width: width, height: width * 1.4)
                let ratio = imgSize.height / imgSize.width
                let h = width * ratio

                let iv = NSImageView()
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.imageAlignment = .alignCenter
                iv.frame = CGRect(x: 0, y: y, width: width, height: h)
                iv.image = loadComicImage(at: url, trim: trimWhitespace)
                container.addSubview(iv)
                imageViews.append(iv)
                pageOffsets.append(y)

                y += h + spacing
            }

            let totalH = max(0, y - spacing)
            container.frame = CGRect(x: 0, y: 0, width: width, height: totalH)
            sv.magnification = CGFloat(zoomScale.wrappedValue)
        }

        @objc func magnificationDidChange(_ note: Notification) {
            guard let sv = note.object as? NSScrollView else { return }
            let scale = Double(sv.magnification)
            if abs(scale - zoomScale.wrappedValue) > 0.01 {
                zoomScale.wrappedValue = scale
            }
        }

        @objc func scrollDidChange(_ note: Notification) {
            guard let sv = scrollView else { return }
            let y = sv.contentView.bounds.origin.y
            let page = calculateVisiblePage(y: y)
            if page != currentPage.wrappedValue {
                currentPage.wrappedValue = page
                lastTrackedPage = page
            }
        }

        private func calculateVisiblePage(y: CGFloat) -> Int {
            for i in (0..<pageOffsets.count).reversed() {
                if y >= pageOffsets[i] - 50 {
                    return min(i, pages.count - 1)
                }
            }
            return 0
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil

            guard let sv = scrollView else { return }
            if sv.magnification > 1.01 {
                sv.animator().setMagnification(1.0, centeredAt: .zero)
            } else {
                let pt = gesture.location(in: sv)
                sv.animator().setMagnification(2.5, centeredAt: pt)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            pendingSingleClick?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onTap()
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
#endif
