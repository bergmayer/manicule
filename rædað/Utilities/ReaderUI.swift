import SwiftUI

// MARK: - View Mode Menu

/// The four view-mode buttons (Automatic / Single / Two / Scrolling) that all
/// readers expose in their menus and toolbars. Use inside a `Menu` or `Section`.
/// `scrollingLabel` accommodates the two label conventions in use:
/// "Continuous Scroll" for image-based readers (PDF, Comic), "Scrolling" for
/// text-based readers (ePub, Text).
struct ViewModeMenuButtons: View {
    let onAutomatic: () -> Void
    let onSinglePage: () -> Void
    let onTwoPage: () -> Void
    let onScrolling: () -> Void
    var scrollingLabel: String = "Scrolling"
    var scrollingIcon: String = "scroll"

    var body: some View {
        Group {
            Button { onAutomatic() } label: { Label("Automatic", systemImage: "rectangle.portrait.and.arrow.right") }
            Button { onSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
            Button { onTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
            Button { onScrolling() } label: { Label(scrollingLabel, systemImage: scrollingIcon) }
        }
    }
}

// MARK: - Fast Scroll Controller

/// Tracks rapid arrow-key repeats to enable fast-scroll behavior (skipping
/// animation, dropping intermediate updates). After a 0.3 s pause the count
/// resets. ePub uses `onCountChanged` to suppress page-turn animation past
/// 4 repeats; the other readers don't need a callback.
@Observable @MainActor
final class FastScrollController {
    private(set) var count: Int = 0
    private var timer: Timer?
    /// Called on every increment with the new count, and once with 0 when the
    /// run resets. Used by ePub to call `webViewProxy.setAnimated(...)`.
    var onCountChanged: ((Int) -> Void)?

    func handle(phase: KeyPress.Phases) {
        if phase == .down { count = 0 }
        count += 1
        onCountChanged?(count)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.count = 0
                self.onCountChanged?(0)
            }
        }
    }
}

// MARK: - Reader Commands

/// Bundle of closures that handle the menu commands every reader supports.
/// Pass to `.readerCommands(...)` to subscribe to all of them at once.
/// Reader-specific notifications (e.g. ePub's `.toggleTableOfContents` or
/// Comic's `.toggleReadingDirection`) stay as inline `.onReceive` calls.
struct ReaderCommandHandlers {
    var onToggleViewMode: () -> Void
    var onBookmark: () -> Void
    var onShowSavedPositions: () -> Void
    var onShowReadingSettings: () -> Void
    var onToggleSearch: () -> Void
    var onToggleImmersive: () -> Void
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
}

private struct ReaderCommandsModifier: ViewModifier {
    let handlers: ReaderCommandHandlers

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleViewMode)) { _ in handlers.onToggleViewMode() }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarkPosition)) { _ in handlers.onBookmark() }
            .onReceive(NotificationCenter.default.publisher(for: .showSavedPositions)) { _ in handlers.onShowSavedPositions() }
            .onReceive(NotificationCenter.default.publisher(for: .showReadingSettings)) { _ in handlers.onShowReadingSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in handlers.onToggleSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleImmersive)) { _ in handlers.onToggleImmersive() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in handlers.onZoomIn() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in handlers.onZoomOut() }
    }
}

extension View {
    /// Subscribes to the eight notification commands that every reader handles.
    /// Reader-specific commands stay as inline `.onReceive` calls.
    func readerCommands(_ handlers: ReaderCommandHandlers) -> some View {
        modifier(ReaderCommandsModifier(handlers: handlers))
    }
}

// MARK: - Viewport Size Tracking

extension View {
    /// Reports the view's own width and height into the given bindings.
    /// Uses `.onGeometryChange` so it doesn't introduce a nested
    /// `GeometryReader` (which would steal layout from the parent).
    /// Readers use this to drive `effectiveTwoUp` from the content area's
    /// actual aspect ratio rather than the window's.
    func trackViewportSize(width: Binding<CGFloat>, height: Binding<CGFloat>) -> some View {
        self.onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            width.wrappedValue = newSize.width
            height.wrappedValue = newSize.height
        }
    }
}

// MARK: - Reader Search State

/// The four search-UI fields every reader has. Per-format result types and
/// dismiss cleanup stay in the reader (PDF clears OCR state, ePub clears the
/// foliate highlight, etc.) — this struct only owns the common shape so the
/// state declarations and SearchBarView wiring line up across readers.
struct ReaderSearchState: Equatable {
    var isShowing: Bool = false
    var query: String = ""
    var currentIndex: Int = 0
    var isSearching: Bool = false

    mutating func reset() {
        isShowing = false
        query = ""
        currentIndex = 0
        isSearching = false
    }
}

// MARK: - Escape Dismissal

private struct EscapeDismissModifier: ViewModifier {
    let isSearchShowing: () -> Bool
    let dismissSearch: () -> Void
    @Binding var showChrome: Bool

    func body(content: Content) -> some View {
        content.onKeyPress(.escape) {
            if isSearchShowing() {
                dismissSearch()
                return .handled
            }
            #if os(iOS)
            if !showChrome {
                showChrome = true
                return .handled
            }
            #endif
            return .ignored
        }
    }
}

extension View {
    /// Standard escape-key behavior across all readers: dismiss search if
    /// open, otherwise (on iOS) reveal hidden chrome. Returns `.ignored` so
    /// other escape handlers up the chain still get a chance.
    func escapeDismisses(searchShowing: @escaping () -> Bool,
                        dismissSearch: @escaping () -> Void,
                        showChrome: Binding<Bool>) -> some View {
        modifier(EscapeDismissModifier(
            isSearchShowing: searchShowing,
            dismissSearch: dismissSearch,
            showChrome: showChrome
        ))
    }
}

