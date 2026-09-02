import SwiftUI

// MARK: - Trackpad Scroll Overlay (iOS)

#if os(iOS)
/// Transparent overlay that catches trackpad pan gestures for page navigation
/// with smooth finger-tracking. Direct touch events pass through so taps and swipes still work.
struct TrackpadScrollOverlay: UIViewRepresentable {
    /// Called during the pan with the cumulative horizontal translation in points.
    var onTranslation: (CGFloat) -> Void
    /// Called when the pan ends. Parameters: final translation, velocity (points/sec).
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> TrackpadPassthroughView {
        let view = TrackpadPassthroughView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.allowedScrollTypesMask = .continuous
        pan.maximumNumberOfTouches = 0
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: TrackpadPassthroughView, context: Context) {
        context.coordinator.onTranslation = onTranslation
        context.coordinator.onEnd = onEnd
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTranslation: onTranslation, onEnd: onEnd) }

    class Coordinator: NSObject {
        var onTranslation: (CGFloat) -> Void
        var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

        init(onTranslation: @escaping (CGFloat) -> Void, onEnd: @escaping (_ translation: CGFloat, _ velocity: CGFloat) -> Void) {
            self.onTranslation = onTranslation
            self.onEnd = onEnd
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let tx = gesture.translation(in: gesture.view).x
            switch gesture.state {
            case .began:
                onTranslation(0)
            case .changed:
                onTranslation(tx)
            case .ended, .cancelled:
                let vx = gesture.velocity(in: gesture.view).x
                onEnd(tx, vx)
            default:
                break
            }
        }
    }
}

/// A UIView that returns nil from hitTest for direct touch events,
/// allowing them to pass through to views underneath. Trackpad events
/// (which don't go through hitTest) are still caught by gesture recognizers.
class TrackpadPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only respond to indirect (trackpad) pointer events
        if let event = event, event.type == .touches {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}
#endif

// MARK: - Scroll Wheel Overlay (macOS)

#if os(macOS)
/// Transparent overlay that catches trackpad scroll wheel events for page navigation.
/// Uses native `momentumPhase` to skip momentum events for clean single-page turns.
struct ScrollWheelOverlay: NSViewRepresentable {
    var onNext: () -> Void
    var onPrevious: () -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        context.coordinator.onNext = onNext
        context.coordinator.onPrevious = onPrevious
    }

    func makeCoordinator() -> Coordinator { Coordinator(onNext: onNext, onPrevious: onPrevious) }

    class Coordinator {
        var onNext: () -> Void
        var onPrevious: () -> Void
        var accumulatedDelta: CGFloat = 0
        var triggered = false

        init(onNext: @escaping () -> Void, onPrevious: @escaping () -> Void) {
            self.onNext = onNext
            self.onPrevious = onPrevious
        }

        func handleScrollWheel(_ event: NSEvent) {
            // Skip momentum events — only respond to direct user input
            if event.momentumPhase != [] { return }

            if event.phase == .began {
                accumulatedDelta = 0
                triggered = false
            }

            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY

            accumulatedDelta += delta

            guard !triggered else { return }

            if abs(accumulatedDelta) > 15 {
                triggered = true
                if accumulatedDelta > 0 { onPrevious() } else { onNext() }
            }
        }
    }
}

/// NSView subclass that captures scroll wheel events for page navigation.
class ScrollWheelView: NSView {
    weak var coordinator: ScrollWheelOverlay.Coordinator?

    override func scrollWheel(with event: NSEvent) {
        coordinator?.handleScrollWheel(event)
    }

    override var acceptsFirstResponder: Bool { false }
}
#endif
