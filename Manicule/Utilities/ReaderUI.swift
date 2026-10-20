import SwiftUI
import Combine

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
            #if !os(macOS)
            // Automatic resolves to single or two-up based on orientation,
            // which only matters on devices that rotate. On macOS the
            // window-size heuristic is a worse fit than picking explicitly.
            Button { onAutomatic() } label: { Label("Automatic", systemImage: "shuffle") }
            #endif
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
            Task { @MainActor [weak self] in
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

/// Subscribes to one reader notification command, firing only when this
/// view's window is key. Menu commands post app-wide notifications; without
/// the key-window check, every open reader window on macOS would act on the
/// same Cmd+D / Cmd+F / etc.
private struct ReaderCommandModifier: ViewModifier {
    let name: Notification.Name
    let action: () -> Void
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var isKeyWindow: Bool {
        #if os(macOS)
        controlActiveState == .key
        #else
        true
        #endif
    }

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: name)) { _ in
            if isKeyWindow { action() }
        }
    }
}

private struct ReaderCommandsModifier: ViewModifier {
    let handlers: ReaderCommandHandlers

    func body(content: Content) -> some View {
        content
            .onReaderCommand(.toggleViewMode, perform: handlers.onToggleViewMode)
            .onReaderCommand(.bookmarkPosition, perform: handlers.onBookmark)
            .onReaderCommand(.showSavedPositions, perform: handlers.onShowSavedPositions)
            .onReaderCommand(.showReadingSettings, perform: handlers.onShowReadingSettings)
            .onReaderCommand(.toggleSearch, perform: handlers.onToggleSearch)
            .onReaderCommand(.toggleImmersive, perform: handlers.onToggleImmersive)
            .onReaderCommand(.zoomIn, perform: handlers.onZoomIn)
            .onReaderCommand(.zoomOut, perform: handlers.onZoomOut)
    }
}

extension View {
    /// Subscribes to the eight notification commands that every reader handles.
    /// Reader-specific commands subscribe individually via `onReaderCommand`.
    func readerCommands(_ handlers: ReaderCommandHandlers) -> some View {
        modifier(ReaderCommandsModifier(handlers: handlers))
    }

    /// Subscribes to a single reader menu command, gated to the key window on
    /// macOS so commands don't hit every open document window.
    func onReaderCommand(_ name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        modifier(ReaderCommandModifier(name: name, action: action))
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
    var error: String?

    mutating func reset() {
        isShowing = false
        query = ""
        currentIndex = 0
        isSearching = false
        error = nil
    }
}

/// Debounces query-change events so search backends (foliate-js generator,
/// PDFKit findString, OCR) don't run on every keystroke. Each reader owns
/// one of these and routes `.onChange(of: search.query)` through it.
///
/// Semantics:
///   - Trimmed query length < `minLength` → invokes `clear` immediately and
///     cancels any pending search (prevents "tally up every 'e'").
///   - Otherwise, cancels the in-flight delay and schedules `perform` after
///     `debounceMilliseconds`.
///   - `submit(query:)` runs `perform` now, skipping the wait (Enter key).
///   - `cancel()` aborts the pending delay; call from dismiss handlers.
@Observable @MainActor
final class SearchDebouncer {
    var debounceMilliseconds: Int = 300
    var minLength: Int = 2

    private var task: Task<Void, Never>?

    func handle(
        _ query: String,
        perform: @escaping (String) -> Void,
        clear: @escaping () -> Void
    ) {
        task?.cancel()
        task = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLength else {
            clear()
            return
        }
        task = Task { @MainActor [debounceMilliseconds] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            if Task.isCancelled { return }
            perform(trimmed)
        }
    }

    func submit(
        _ query: String,
        perform: @escaping (String) -> Void
    ) {
        task?.cancel()
        task = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLength else { return }
        perform(trimmed)
    }

    func cancel() {
        task?.cancel()
        task = nil
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


private struct ReaderSearchErrorModifier: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert("Search Interrupted", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

extension View {
    func readerSearchError(_ error: Binding<String?>) -> some View {
        modifier(ReaderSearchErrorModifier(error: error))
    }
}

/// A mostly opaque tint keeps reader controls legible over page content. Respect the
/// system's Reduce Transparency preference without dimming the controls themselves.
struct ReaderChromeBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Rectangle()
            .fill(.background)
            .opacity(reduceTransparency ? 1 : 0.95)
    }
}

/// Page numbers are one-based in the UI; navigation callbacks use source indices.
struct ReaderPageField: View {
    let page: Int
    let pageCount: Int
    let goToPage: (Int) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var label = "Page"
    var isEstimated = false
    @State private var keyboardVisible = false
    @State private var pendingPage: Int?
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var target: Int? { PageNavigation.requestedIndex(draft, pageCount: pageCount) }

    var body: some View {
        HStack(spacing: 6) {
            Button(label) { isEditing = true }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("reader-page-focus")
            TextField(String(page), text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: max(48, CGFloat(String(max(1, pageCount)).count) * 10), height: 44)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.25))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { isEditing = true })
                .focused($isEditing)
                .accessibilityLabel(isEstimated ? "Estimated page number" : "Page number")
                .accessibilityHint("Enter a page from 1 to \(pageCount), then press Return or tap Go")
                .accessibilityIdentifier("reader-page-number")
                #if os(iOS) || os(visionOS)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.go)
                #endif
                .onSubmit(commit)
            if isEditing {
                Button(action: commit) {
                    Text("Go").frame(minWidth: 36, minHeight: 32)
                }
                    .buttonStyle(.bordered)
                    .disabled(target == nil)
                    .accessibilityIdentifier("reader-page-go")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .onAppear { draft = String(page) }
        .onChange(of: page) { _, newPage in
            if !isEditing && !keyboardVisible { draft = String(newPage) }
        }
        .onChange(of: isEditing) { _, editing in
            // UIKit can end editing before SwiftUI delivers onSubmit (notably
            // on iPhone). Preserve the entered number until submission reads it.
            if editing { draft = "" }
            if editing || !keyboardVisible { onEditingChanged(editing) }
        }
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification).receive(on: DispatchQueue.main)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification).receive(on: DispatchQueue.main)) { _ in
            keyboardVisible = false
            if let page = pendingPage {
                pendingPage = nil
                DispatchQueue.main.async { goToPage(page) }
            }
            if !isEditing {
                draft = String(page)
                onEditingChanged(false)
            }
        }
        #endif
        .onDisappear { Task { @MainActor in onEditingChanged(false) } }
    }

    private func commit() {
        guard pendingPage == nil, let target else { return }
        // Foliate restores its viewport anchor during keyboard resizing. Navigate
        // after that resize finishes so it cannot overwrite the requested page.
        if keyboardVisible {
            pendingPage = target
            isEditing = false
        } else {
            isEditing = false
            DispatchQueue.main.async { goToPage(target) }
        }
    }
}
