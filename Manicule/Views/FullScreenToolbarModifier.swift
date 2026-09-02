import SwiftUI

#if os(macOS)
import AppKit

/// Hides the window toolbar in full-screen mode and reveals it on mouse hover
/// near the top of the screen, matching standard macOS full-screen behavior.
/// Also syncs the `showChrome` binding so the bottom status bar follows the toolbar.
private struct FullScreenToolbarModifier: ViewModifier {
    @Binding var showChrome: Bool
    @State private var isFullScreen = false
    @State private var mouseNearTop = false
    @State private var hideTask: Task<Void, Never>?

    private var toolbarVisible: Bool {
        !isFullScreen || showChrome
    }

    func body(content: Content) -> some View {
        content
            .toolbarVisibility(toolbarVisible ? .visible : .hidden, for: .windowToolbar)
            .background(WindowFullScreenTracker(
                isFullScreen: $isFullScreen,
                mouseNearTop: $mouseNearTop
            ))
            .onChange(of: mouseNearTop) { _, nearTop in
                guard isFullScreen else { return }
                if nearTop {
                    hideTask?.cancel()
                    showChrome = true
                } else {
                    scheduleHide()
                }
            }
            .onChange(of: isFullScreen) { _, fullScreen in
                if fullScreen {
                    scheduleHide()
                } else {
                    hideTask?.cancel()
                    mouseNearTop = false
                    showChrome = true
                }
            }
            .onChange(of: showChrome) { _, chrome in
                // When chrome is toggled on manually (center-click) in fullscreen,
                // schedule auto-hide so it doesn't stay forever.
                if isFullScreen && chrome && !mouseNearTop {
                    scheduleHide()
                }
            }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, isFullScreen else { return }
            showChrome = false
        }
    }
}

/// Invisible NSView that observes its owning window's full-screen transitions
/// and monitors mouse position near the top of the screen in full-screen mode.
private struct WindowFullScreenTracker: NSViewRepresentable {
    @Binding var isFullScreen: Bool
    @Binding var mouseNearTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onFullScreenChange = { fullScreen in
            isFullScreen = fullScreen
        }
        view.onMouseNearTopChange = { nearTop in
            mouseNearTop = nearTop
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class TrackingView: NSView {
        var onFullScreenChange: ((Bool) -> Void)?
        var onMouseNearTopChange: ((Bool) -> Void)?
        private var enterObserver: NSObjectProtocol?
        private var exitObserver: NSObjectProtocol?
        private var mouseMonitor: Any?
        private var globalMonitor: Any?
        private var isInFullScreen = false
        private var currentlyNearTop = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let o = enterObserver { NotificationCenter.default.removeObserver(o) }
            if let o = exitObserver { NotificationCenter.default.removeObserver(o) }
            stopMouseMonitoring()

            guard let window else { return }

            let alreadyFullScreen = window.styleMask.contains(.fullScreen)
            isInFullScreen = alreadyFullScreen
            onFullScreenChange?(alreadyFullScreen)
            if alreadyFullScreen { startMouseMonitoring() }

            enterObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                self?.isInFullScreen = true
                self?.onFullScreenChange?(true)
                self?.startMouseMonitoring()
            }

            exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                self?.isInFullScreen = false
                self?.onFullScreenChange?(false)
                self?.stopMouseMonitoring()
                self?.updateNearTop(false)
            }
        }

        private func startMouseMonitoring() {
            guard mouseMonitor == nil else { return }
            checkMousePosition()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate]
            ) { [weak self] event in
                self?.checkMousePosition()
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved]
            ) { [weak self] _ in
                self?.checkMousePosition()
            }
        }

        private func stopMouseMonitoring() {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
                globalMonitor = nil
            }
        }

        private func checkMousePosition() {
            guard let screen = window?.screen else { return }
            let mouseY = NSEvent.mouseLocation.y
            let nearTop = mouseY >= screen.frame.maxY - 60
            updateNearTop(nearTop)
        }

        private func updateNearTop(_ nearTop: Bool) {
            guard nearTop != currentlyNearTop else { return }
            currentlyNearTop = nearTop
            onMouseNearTopChange?(nearTop)
        }

        deinit {
            stopMouseMonitoring()
            if let o = enterObserver { NotificationCenter.default.removeObserver(o) }
            if let o = exitObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}
#endif

extension View {
    /// On macOS, hides the window toolbar in full-screen mode and reveals it
    /// when the mouse hovers near the top of the screen. Also syncs the
    /// showChrome binding so the bottom status bar follows the toolbar.
    func fullScreenToolbarAutoHide(showChrome: Binding<Bool> = .constant(true)) -> some View {
        #if os(macOS)
        modifier(FullScreenToolbarModifier(showChrome: showChrome))
        #else
        self
        #endif
    }
}
