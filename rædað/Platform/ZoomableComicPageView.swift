#if os(macOS)
import SwiftUI

/// Tap zone for page navigation: left third, center third, right third.
enum TapZone {
    case left, center, right
}

/// A zoomable comic page view (macOS single-page mode) using NSScrollView for
/// pinch-to-zoom, double-click zoom toggle, pan when zoomed, click zone
/// detection, and trackpad/scroll-wheel page turning at 1x zoom.
/// (iOS paginated comics use PaginatedComicContainerView instead.)
struct ZoomableComicPageView: NSViewRepresentable {
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

        // Reload when the image URL or the trim setting changed
        if context.coordinator.currentURL != imageURL || context.coordinator.currentTrim != trimWhitespace {
            if let imageView = context.coordinator.imageView {
                loadImage(into: imageView, scrollView: scrollView, context: context)
            }
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
        context.coordinator.currentTrim = trimWhitespace
    }

    class Coordinator: NSObject {
        var zoomScale: Binding<Double>
        var onTapZone: (TapZone) -> Void
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var imageView: NSImageView?
        weak var scrollView: NSScrollView?
        var currentURL: URL?
        var currentTrim: Bool?
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
class PageTurnScrollView: NSScrollView {
    weak var coordinator: ZoomableComicPageView.Coordinator?
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
