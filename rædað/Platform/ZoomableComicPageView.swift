import SwiftUI

/// Tap zone for page navigation: left third, center third, right third.
enum TapZone {
    case left, center, right
}

/// A zoomable comic page view using platform-native scroll views for pinch-to-zoom,
/// double-tap/click zoom toggle, pan when zoomed, tap zone detection, and
/// trackpad/scroll-wheel page turning at 1x zoom.
struct ZoomableComicPageView: View {
    let imageURL: URL
    let viewSize: CGSize
    var trimWhitespace: Bool = false
    let onTapZone: (TapZone) -> Void
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    @Binding var zoomScale: Double

    var body: some View {
        #if os(iOS)
        ZoomableComicPageView_iOS(
            imageURL: imageURL,
            viewSize: viewSize,
            trimWhitespace: trimWhitespace,
            onTapZone: onTapZone,
            onNext: onNext,
            onPrevious: onPrevious,
            zoomScale: $zoomScale
        )
        #elseif os(macOS)
        ZoomableComicPageView_macOS(
            imageURL: imageURL,
            viewSize: viewSize,
            trimWhitespace: trimWhitespace,
            onTapZone: onTapZone,
            onNext: onNext,
            onPrevious: onPrevious,
            zoomScale: $zoomScale
        )
        #endif
    }
}

// MARK: - iOS Implementation

#if os(iOS)
private struct ZoomableComicPageView_iOS: UIViewRepresentable {
    let imageURL: URL
    let viewSize: CGSize
    var trimWhitespace: Bool = false
    let onTapZone: (TapZone) -> Void
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    @Binding var zoomScale: Double

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        // Double-tap to toggle zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Single-tap for zone detection (waits for double-tap to fail)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // Trackpad pan for page turning (trackpad only, no direct touch)
        let trackpadPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTrackpadPan(_:)))
        trackpadPan.allowedScrollTypesMask = .continuous
        trackpadPan.maximumNumberOfTouches = 0
        scrollView.addGestureRecognizer(trackpadPan)

        loadImage(into: imageView, scrollView: scrollView)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onTapZone = onTapZone
        context.coordinator.onNext = onNext
        context.coordinator.onPrevious = onPrevious

        // If image URL changed, reload
        if context.coordinator.currentURL != imageURL {
            if let imageView = context.coordinator.imageView {
                loadImage(into: imageView, scrollView: scrollView)
            }
            context.coordinator.currentURL = imageURL
        }

        // Sync external zoom scale changes (e.g. Cmd+/-)
        let current = scrollView.zoomScale
        let target = CGFloat(zoomScale)
        if abs(current - target) > 0.01 {
            scrollView.setZoomScale(target, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, onTapZone: onTapZone, onNext: onNext, onPrevious: onPrevious)
    }

    private func loadImage(into imageView: UIImageView, scrollView: UIScrollView) {
        imageView.image = loadComicImage(at: imageURL, trim: trimWhitespace)
        imageView.frame = CGRect(origin: .zero, size: viewSize)
        scrollView.contentSize = viewSize
        scrollView.zoomScale = CGFloat(zoomScale)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var zoomScale: Binding<Double>
        var onTapZone: (TapZone) -> Void
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var imageView: UIImageView?
        var currentURL: URL?
        private var trackpadTriggered = false

        init(zoomScale: Binding<Double>, onTapZone: @escaping (TapZone) -> Void,
             onNext: (() -> Void)?, onPrevious: (() -> Void)?) {
            self.zoomScale = zoomScale
            self.onTapZone = onTapZone
            self.onNext = onNext
            self.onPrevious = onPrevious
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
            let newScale = Double(scrollView.zoomScale)
            if abs(newScale - zoomScale.wrappedValue) > 0.01 {
                zoomScale.wrappedValue = newScale
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            guard let imageView = imageView else { return }
            let boundsSize = scrollView.bounds.size
            let contentSize = imageView.frame.size
            let offsetX = max(0, (boundsSize.width - contentSize.width) / 2)
            let offsetY = max(0, (boundsSize.height - contentSize.height) / 2)
            imageView.center = CGPoint(
                x: contentSize.width / 2 + offsetX,
                y: contentSize.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let zoomRect = zoomRect(for: 2.5, center: point, in: scrollView)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view else { return }
            let x = gesture.location(in: scrollView).x
            let width = scrollView.bounds.width
            if x < width / 3 {
                onTapZone(.left)
            } else if x > width * 2 / 3 {
                onTapZone(.right)
            } else {
                onTapZone(.center)
            }
        }

        @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView,
                  scrollView.zoomScale <= 1.01 else { return }
            switch gesture.state {
            case .began:
                trackpadTriggered = false
            case .changed:
                guard !trackpadTriggered else { return }
                let tx = gesture.translation(in: gesture.view).x
                if abs(tx) > 20 {
                    trackpadTriggered = true
                    if tx < 0 { onNext?() } else { onPrevious?() }
                }
            default:
                break
            }
        }

        private func zoomRect(for scale: CGFloat, center: CGPoint, in scrollView: UIScrollView) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}
#endif

// MARK: - macOS Implementation

#if os(macOS)
private struct ZoomableComicPageView_macOS: NSViewRepresentable {
    let imageURL: URL
    let viewSize: CGSize
    var trimWhitespace: Bool = false
    let onTapZone: (TapZone) -> Void
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    @Binding var zoomScale: Double

    func makeNSView(context: Context) -> PageTurnScrollView {
        let scrollView = PageTurnScrollView()
        scrollView.coordinator = context.coordinator
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let imageView = FlippedNSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        // Attach click gestures to the document view (not the scroll view)
        // so that clicks on scroll bars reach the scrollers instead of
        // being intercepted by our gesture recognizers.
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        let singleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleClick(_:)))
        singleClick.numberOfClicksRequired = 1
        imageView.addGestureRecognizer(singleClick)

        loadImage(into: imageView, scrollView: scrollView, context: context)

        // Observe magnification changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: PageTurnScrollView, context: Context) {
        context.coordinator.onTapZone = onTapZone
        context.coordinator.onNext = onNext
        context.coordinator.onPrevious = onPrevious

        // If image URL changed, reload
        if context.coordinator.currentURL != imageURL {
            if let imageView = context.coordinator.imageView {
                loadImage(into: imageView, scrollView: scrollView, context: context)
            }
            context.coordinator.currentURL = imageURL
        }

        // Re-layout when view size changes (e.g. initial 0x0 → real size)
        if let imageView = context.coordinator.imageView,
           imageView.image != nil,
           viewSize.width > 0, viewSize.height > 0 {
            let currentFrame = imageView.frame.size
            if abs(currentFrame.width - viewSize.width) > 1 || abs(currentFrame.height - viewSize.height) > 1 {
                imageView.frame = CGRect(origin: .zero, size: viewSize)
            }
        }

        // Sync external zoom scale changes (e.g. Cmd+/-)
        let current = scrollView.magnification
        let target = CGFloat(zoomScale)
        if abs(current - target) > 0.01 {
            scrollView.animator().magnification = target
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, onTapZone: onTapZone, onNext: onNext, onPrevious: onPrevious)
    }

    private func loadImage(into imageView: NSImageView, scrollView: NSScrollView, context: Context) {
        imageView.image = loadComicImage(at: imageURL, trim: trimWhitespace)
        imageView.frame = CGRect(origin: .zero, size: viewSize)
        scrollView.magnification = CGFloat(zoomScale)
        context.coordinator.currentURL = imageURL
    }

    class Coordinator: NSObject {
        var zoomScale: Binding<Double>
        var onTapZone: (TapZone) -> Void
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var imageView: NSImageView?
        weak var scrollView: NSScrollView?
        var currentURL: URL?
        private var pendingSingleClick: DispatchWorkItem?
        var accumulatedScrollDelta: CGFloat = 0
        var scrollTriggered = false

        init(zoomScale: Binding<Double>, onTapZone: @escaping (TapZone) -> Void,
             onNext: (() -> Void)?, onPrevious: (() -> Void)?) {
            self.zoomScale = zoomScale
            self.onTapZone = onTapZone
            self.onNext = onNext
            self.onPrevious = onPrevious
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            let newScale = Double(scrollView.magnification)
            if abs(newScale - zoomScale.wrappedValue) > 0.01 {
                zoomScale.wrappedValue = newScale
            }
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil

            guard let scrollView = scrollView else { return }
            if scrollView.magnification > 1.01 {
                scrollView.animator().setMagnification(1.0, centeredAt: .zero)
            } else {
                let point = gesture.location(in: scrollView)
                scrollView.animator().setMagnification(2.5, centeredAt: point)
            }
        }

        @objc func handleSingleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            let x = gesture.location(in: scrollView).x
            let width = scrollView.bounds.width

            pendingSingleClick?.cancel()
            let zone: TapZone
            if x < width / 3 {
                zone = .left
            } else if x > width * 2 / 3 {
                zone = .right
            } else {
                zone = .center
            }
            let work = DispatchWorkItem { [weak self] in
                self?.onTapZone(zone)
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }

        func handleScrollWheel(_ event: NSEvent) {
            // Skip momentum events
            if event.momentumPhase != [] { return }

            if event.phase == .began {
                accumulatedScrollDelta = 0
                scrollTriggered = false
            }

            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            accumulatedScrollDelta += delta

            guard !scrollTriggered else { return }
            if abs(accumulatedScrollDelta) > 15 {
                scrollTriggered = true
                if accumulatedScrollDelta > 0 { onPrevious?() } else { onNext?() }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// NSScrollView subclass that intercepts scroll wheel events for page turning at 1x zoom,
/// while letting magnify gestures (trackpad pinch) pass through to the native handler.
private class PageTurnScrollView: NSScrollView {
    weak var coordinator: ZoomableComicPageView_macOS.Coordinator?
    private var didInitialDisplay = false

    override func layout() {
        super.layout()
        // On the first layout pass with real bounds, force the scroll view
        // to recalculate its internal state. This fixes the case where the
        // document view's frame was set in makeNSView before the scroll view
        // had its own bounds, leaving the clip view in a stale state.
        if !didInitialDisplay && bounds.width > 0 {
            didInitialDisplay = true
            tile()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // When at 1x magnification, use scroll wheel for page turning
        if magnification <= 1.01 {
            coordinator?.handleScrollWheel(event)
        } else {
            // When zoomed in, let NSScrollView handle panning
            super.scrollWheel(with: event)
        }
    }
}

#endif
