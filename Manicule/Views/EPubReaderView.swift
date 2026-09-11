import SwiftUI
import AVFoundation

/// Both margin pairs as a single Equatable value for SwiftUI .onChange.
private struct MarginPair: Equatable {
    let oneUp: MarginSettings
    let twoUp: MarginSettings
}

/// Displays an ePub book using foliate-js web components with built-in pagination,
/// touch handling, and CFI-based navigation.
struct EPubReaderView: View {
    let book: EPubBook
    let fileURL: URL?
    let rawData: Data
    @Environment(\.readingSession) private var readingSession
    let fileHash: String
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    @State private var currentFraction: Double = 0.0
    @State private var currentCFI: String?
    @State private var currentTOCLabel: String?
    @State private var atStart: Bool = true
    @State private var atEnd: Bool = false
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 1
    @State private var sectionIndex: Int = 0
    @State private var sectionCount: Int = 1

    // UI state
    @State private var showTOC: Bool = false
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    private var viewMode: ViewMode { readingPrefs.effective(for: fileHash).viewMode }
    private var twoUpOverride: Bool? { readingPrefs.effective(for: fileHash).twoUp }
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @State private var webViewProxy = WebViewProxy()
    @State private var bridgeReady = false
    @State private var bookDirectory: TemporaryDirectoryLease?
    @State private var bookLoadError: String?
    @State private var loadAttempt = UUID()
    @State private var positionRestoreTask: Task<Void, Never>?
    private var bookTempURL: URL? { bookDirectory?.url.appendingPathComponent("book.epub") }

    @State private var fastScroll = FastScrollController()

    // Read-aloud state (iOS only)
    #if os(iOS) || os(visionOS)
    private let readAloud = ReadAloudController.shared
    @State private var narrationOwner = UUID()
    private var ownsNarration: Bool { readAloud.owner == narrationOwner }
    private var narrationIsActive: Bool { ownsNarration && readAloud.isActive }
    @State private var readAloudSectionIndex: Int = -1
    @State private var readAloudEmptySections: Int = 0
    @State private var readAloudLastSeekTime: Date = .distantPast
    #endif

    // Search state
    @State private var search = ReaderSearchState()
    @State private var searchResults: [[String: String]] = []
    @State private var searchDebouncer = SearchDebouncer()

    @Environment(\.horizontalSizeClass) private var sizeClass

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var isPaginated: Bool {
        viewMode == .paginated
    }

    private var effectiveTwoUp: Bool {
        guard isPaginated else { return false }
        return twoUpOverride ?? ReaderHelpers.defaultTwoUp(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Both margin pairs as a single Equatable value, used to drive a single
    /// onChange that re-sends to the bridge whenever either pair changes (e.g.
    /// the user moves a slider in Reading Settings).
    private var marginPairs: MarginPair {
        let effective = readingPrefs.effective(for: fileHash)
        return MarginPair(oneUp: effective.marginsOneUp, twoUp: effective.marginsTwoUp)
    }

    private func sendBothMargins() {
        let m = marginPairs
        webViewProxy.setMarginsBoth?(m.oneUp.topBottom, m.oneUp.leftRight,
                                      m.twoUp.topBottom, m.twoUp.leftRight)
    }

    var body: some View {
        epubLayoutWithToolbar
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash) { position in
                        if case .epubCFI(let cfi, _) = position, !cfi.isEmpty {
                            webViewProxy.goTo?(cfi)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ReaderSettingsSheet(fileHash: fileHash)
            }
            .onChange(of: readingPrefs.effective(for: fileHash).foliateCSS) { _, newCSS in
                webViewProxy.setStyles?(newCSS)
            }
            // The bridge owns per-orientation margin selection — when the user
            // edits either pair in Reading Settings we re-send both, and the
            // bridge picks the matching one based on its resolved column count.
            .readerSearchError($search.error)
            .onChange(of: viewMode) { _, _ in
                webViewProxy.setFlow?(isPaginated ? "paginated" : "scrolled")
                restoreCurrentPosition()
            }
            .onChange(of: twoUpOverride) { _, value in
                webViewProxy.setColumnCount?(ReaderHelpers.resolveColumnCountForBridge(value))
                restoreCurrentPosition()
            }
            .onChange(of: marginPairs) { _, _ in
                sendBothMargins()
            }
    }

    @ViewBuilder
    private var epubLayoutWithToolbar: some View {
        epubLayoutWithNotifications
            #if os(macOS)
            .toolbar { epubToolbar }
            #endif
            .fullScreenToolbarAutoHide(showChrome: $showChrome)
            .task(id: showTOC) {
                guard !showTOC else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                webViewProxy.refocus?()
            }
            .task(id: loadAttempt) {
                ReaderHelpers.migrateLegacyIdentity(data: rawData, currentHash: fileHash)
                readingPrefs.touchLastUsed(for: fileHash)
                wireFastScrollAnimationSuppression()
                let bookData = rawData
                bookDirectory = nil
                bookLoadError = nil
                bridgeReady = false
                do {
                    let worker = Task.detached(priority: .utility) {
                        try Task.checkCancellation()
                        return try TemporaryDirectoryLease.writing(bookData, filename: "book.epub")
                    }
                    let directory = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    bookDirectory = directory
                } catch is CancellationError {
                    // The local lease releases any completed temporary file.
                } catch {
                    guard !Task.isCancelled else { return }
                    bookLoadError = error.localizedDescription
                }
            }
            .onDisappear {
                autoSavePosition()
                searchDebouncer.cancel()
                positionRestoreTask?.cancel()
                webViewProxy.clearSearch?()
                bookDirectory = nil
                #if os(iOS) || os(visionOS)
                readAloud.dismiss(for: narrationOwner)
                #endif
            }
    }

    @ViewBuilder
    private var epubLayoutWithNotifications: some View {
        epubLayout
            .readerCommands(ReaderCommandHandlers(
                onToggleViewMode: { if isPaginated { selectScrolling() } else { selectSinglePage() } },
                onBookmark: toggleBookmark,
                onShowSavedPositions: { showBookmarks = true },
                onShowReadingSettings: { showSettings = true },
                onToggleSearch: {
                    search.isShowing.toggle()
                    if !search.isShowing { dismissSearch() }
                },
                onToggleImmersive: { showChrome.toggle() },
                onZoomIn: { adjustFontSize(by: 1) },
                onZoomOut: { adjustFontSize(by: -1) }
            ))
            .onReaderCommand(.toggleTableOfContents) {
                withAnimation { showTOC.toggle() }
            }
            .onReaderCommand(.nextChapter, perform: goToNextChapter)
            .onReaderCommand(.previousChapter, perform: goToPreviousChapter)
            #if os(iOS) || os(visionOS)
            .onReaderCommand(.toggleReadAloud, perform: toggleReadAloud)
            #endif
            .onChange(of: search.query) { _, newQuery in
                clearEPubSearch()
                searchDebouncer.handle(newQuery, perform: performEPubSearch, clear: clearEPubSearch)
            }
    }

    @ViewBuilder
    private var epubLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                epubContent
                    .trackViewportSize(width: $viewWidth, height: $viewHeight)

                if showTOC && sizeClass != .compact {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation { showTOC = false }
                        }

                    HStack(spacing: 0) {
                        TableOfContentsView(
                            entries: book.tableOfContents,
                            currentTOCLabel: currentTOCLabel,
                            bookmarkTOCLabels: Set(bookmarkStore.bookmarks(for: fileHash).compactMap(\.tocLabel)),
                            onSelect: { entry in
                                navigateToTOCEntry(entry)
                            }
                        )
                        .frame(width: 280)
                        .overlay(alignment: .trailing) {
                            // Invisible edge handle for swipe-to-close
                            Color.clear
                                .frame(width: 30)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 20)
                                    .onEnded { value in
                                        if value.translation.width < -40 {
                                            withAnimation { showTOC = false }
                                        }
                                    }
                                )
                        }
                        Divider()
                    }
                    .frame(maxHeight: .infinity)
                    .background(.bar)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 2)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
                }
            }
        }
        .navigationTitle(book.metadata.title)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            fastScroll.handle(phase: event.phase)
            goBack()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            fastScroll.handle(phase: event.phase)
            goForward()
            return .handled
        }
        #if os(iOS)
        .background((readingPrefs.effective(for: fileHash).theme.swiftUIBackground ?? Color(.systemBackground)).ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .automatic)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: Binding(
            get: { showTOC && sizeClass == .compact },
            set: { if !$0 { showTOC = false } }
        )) {
            NavigationStack {
                TableOfContentsView(
                    entries: book.tableOfContents,
                    currentTOCLabel: currentTOCLabel,
                    bookmarkTOCLabels: Set(bookmarkStore.bookmarks(for: fileHash).compactMap(\.tocLabel)),
                    onSelect: { entry in
                        navigateToTOCEntry(entry)
                        showTOC = false
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showTOC = false }
                    }
                }
            }
        }
        #endif
        .preferredColorScheme(readingPrefs.effective(for: fileHash).theme.preferredColorScheme)
        .escapeDismisses(
            searchShowing: { search.isShowing },
            dismissSearch: dismissSearch,
            showChrome: $showChrome
        )
        .overlay(alignment: .top) {
            if search.isShowing {
                SearchBarView(
                    query: $search.query,
                    isSearching: $search.isSearching,
                    resultCount: searchResults.count,
                    currentResult: searchResults.isEmpty ? 0 : search.currentIndex + 1,
                    onNext: { navigateSearchResult(forward: true) },
                    onPrevious: { navigateSearchResult(forward: false) },
                    onDismiss: { dismissSearch() },
                    minQueryLength: searchDebouncer.minLength
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: search.isShowing)
        #if os(iOS) || os(visionOS)
        // Overlay top bar (covers text, no reflow)
        .overlay(alignment: .top) {
            if showChrome {
                iOSTopBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        // Bottom chrome overlays (no reflow)
        .overlay(alignment: .bottom) {
            if showChrome {
                if narrationIsActive {
                    ReadAloudBarView(controller: readAloud) {
                        dismissReadAloud()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    progressSlider
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            if showChrome {
                progressSlider
            }
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var epubContent: some View {
        if let bookTempURL, bookLoadError == nil {
            WebViewRepresentable(
                content: WebViewContent(
                    fileURL: URL(fileURLWithPath: "/"),
                    baseURL: URL(fileURLWithPath: "/"),
                    scrollFraction: nil,
                    fragment: nil,
                    cssOverride: nil,
                    paginated: isPaginated,
                    isEPub: true,
                    bookFileURL: bookTempURL,
                    resourceLease: bookDirectory
                ),
                proxy: webViewProxy,
                onScrollPositionChange: { fraction in
                    currentFraction = fraction
                },
                onRelocate: { event in
                    handleRelocate(event)
                },
                onBridgeReady: {
                    bridgeReady = true
                    openBookInBridge()
                },
                onToggleChrome: {
                    guard !showTOC else { return }
                    showChrome.toggle()
                },
                onSearchResult: { results, done in
                    searchResults = results
                    if done { search.isSearching = false }
                    if !results.isEmpty && search.currentIndex >= results.count {
                        search.currentIndex = 0
                    }
                },
                onReadAloudSectionText: readAloudSectionTextHandler,
                onReadAloudSeek: readAloudSeekHandler,
                onFailure: { message in
                    search.isSearching = false
                    bookLoadError = message
                },
                onSearchFailure: { message in
                    search.isSearching = false
                    search.error = message
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .overlay {
                if isPaginated {
                    ScrollWheelOverlay(
                        onNext: { goForward() },
                        onPrevious: { goBack() }
                    )
                }
            }
            #endif
        } else if let bookLoadError {
            ContentUnavailableView {
                Label("Unable to Display ePub", systemImage: "book.closed")
            } description: {
                Text(bookLoadError)
            } actions: {
                Button("Retry") { loadAttempt = UUID() }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    private var currentModeIcon: String {
        ReaderHelpers.viewModeIcon(isPaginated: isPaginated, twoUpOverride: twoUpOverride)
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var epubToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: goBack) {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(atStart)

            Button(action: goForward) {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(atEnd)
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                ViewModeMenuButtons(
                    onAutomatic: selectAutomatic,
                    onSinglePage: selectSinglePage,
                    onTwoPage: selectTwoPage,
                    onScrolling: selectScrolling
                )
            } label: {
                Label("View Mode", systemImage: currentModeIcon)
            }
        }

        if isPaginated {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: goToPreviousChapter) {
                    Label("Previous Chapter", systemImage: "backward.end")
                }
                Button(action: goToNextChapter) {
                    Label("Next Chapter", systemImage: "forward.end")
                }
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { withAnimation { showTOC.toggle() } } label: {
                Label("Table of Contents", systemImage: showTOC ? "list.bullet.indent" : "list.bullet")
            }
            .disabled(book.tableOfContents.isEmpty)
        }

        ToolbarItem(placement: .automatic) {
            Button { toggleBookmark() } label: {
                Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { search.isShowing.toggle(); if !search.isShowing { dismissSearch() } } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { showSettings = true } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
        }
    }
    #endif

    // MARK: - iOS Overlay Chrome

    #if os(iOS) || os(visionOS)
    @ViewBuilder
    private var iOSTopBar: some View {
        HStack {
            HStack(spacing: 16) {
                if !book.tableOfContents.isEmpty && sizeClass != .compact {
                    Button {
                        withAnimation { showTOC.toggle() }
                    } label: {
                        Label(
                            showTOC ? "Hide Table of Contents" : "Show Table of Contents",
                            systemImage: "sidebar.leading"
                        )
                    }
                    .labelStyle(.iconOnly)
                }

                if let onClose {
                    if narrationIsActive {
                        Button {
                            // Full teardown — also exits the bridge's read-aloud
                            // mode, not just the controller.
                            dismissReadAloud()
                        } label: {
                            Label("Done", systemImage: "speaker.wave.2.fill")
                        }
                    } else {
                        Button("Close Book", action: onClose)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(book.metadata.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Menu {
                Section {
                    ViewModeMenuButtons(
                        onAutomatic: selectAutomatic,
                        onSinglePage: selectSinglePage,
                        onTwoPage: selectTwoPage,
                        onScrolling: selectScrolling
                    )
                }
                Section {
                    if !book.tableOfContents.isEmpty {
                        Button { withAnimation { showTOC.toggle() } } label: {
                            Label(
                                showTOC ? "Hide Table of Contents" : "Show Table of Contents",
                                systemImage: "sidebar.leading"
                            )
                        }
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { search.isShowing.toggle(); if !search.isShowing { dismissSearch() } } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                if isPaginated {
                    Section {
                        Button { goToPreviousChapter() } label: { Label("Previous Chapter", systemImage: "backward.end") }
                        Button { goToNextChapter() } label: { Label("Next Chapter", systemImage: "forward.end") }
                    }
                }
                Section {
                    Button { toggleReadAloud() } label: {
                        Label(narrationIsActive ? "Stop Read Aloud" : "Read Aloud",
                              systemImage: narrationIsActive ? "speaker.slash" : "speaker.wave.2")
                    }
                }
                Section {
                    Button { showSettings = true } label: { Label("Reading Settings", systemImage: "textformat.size") }
                    Button { showBookmarks = true } label: { Label("Go to Bookmark...", systemImage: "bookmark") }
                }
            } label: {
                Label("Menu", systemImage: "ellipsis.circle")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 20)
        .background {
            Rectangle().fill(.bar).ignoresSafeArea(edges: .top)
        }
    }
    #endif

    @ViewBuilder
    private var progressSlider: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { currentFraction.isNaN || currentFraction.isInfinite ? 0.0 : currentFraction },
                    set: { newValue in
                        webViewProxy.goToFraction?(newValue)
                    }
                ),
                in: 0...1
            )
            .padding(.horizontal)
            .padding(.top, 6)
            HStack {
                Text(progressLabel).font(.caption).monospacedDigit().lineLimit(1)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var progressLabel: String {
        let chapterPct = totalPages > 0 ? Int(Double(currentPage) / Double(totalPages) * 100) : 0
        let safeFraction = currentFraction.isNaN || currentFraction.isInfinite ? 0.0 : currentFraction
        let bookPct = Int(safeFraction * 100)
        return "chapter: \(chapterPct)%  book: \(bookPct)%"
    }

    // MARK: - Navigation

    private func goBack() {
        isPaginated ? webViewProxy.previousPage?() : webViewProxy.previousSection?()
    }

    private func goForward() {
        isPaginated ? webViewProxy.nextPage?() : webViewProxy.nextSection?()
    }

    private func goToPreviousChapter() {
        webViewProxy.previousSection?()
    }

    private func goToNextChapter() {
        webViewProxy.nextSection?()
    }

    private func navigateToTOCEntry(_ entry: EPubBook.TOCEntry) {
        webViewProxy.goTo?(entry.href)
    }

    // MARK: - Bridge integration

    private func openBookInBridge() {
        guard bridgeReady else { return }

        let effective = readingPrefs.effective(for: fileHash)
        let flow = isPaginated ? "paginated" : "scrolled"
        let css = effective.foliateCSS
        let oneUp = effective.marginsOneUp
        let twoUp = effective.marginsTwoUp
        // nil = 'auto' (foliate handles orientation internally on iPad/Mac);
        // 1 / 2 force a fixed column count. iPhone always gets 1.
        let cols = ReaderHelpers.resolveColumnCountForBridge(twoUpOverride)

        // Load position for restoration: auto-saved position first, then manual bookmarks
        let lastCFI: String?
        if let autoSaved = bookmarkStore.savedPosition(for: fileHash),
           case .epubCFI(let cfi, _) = autoSaved.position, !cfi.isEmpty {
            lastCFI = cfi
        } else if let mostRecent = bookmarkStore.bookmarks(for: fileHash).first {
            switch mostRecent.position {
            case .epubCFI(let cfi, _) where !cfi.isEmpty:
                lastCFI = cfi
            default:
                lastCFI = nil
            }
        } else {
            lastCFI = nil
        }

        // Open book, apply settings, and init navigation in one chained call.
        // Both margin pairs go to the bridge so it can pick the right one
        // when the resolved column count flips on rotation.
        webViewProxy.openAndInit?(flow, css,
                                  oneUp.topBottom, oneUp.leftRight,
                                  twoUp.topBottom, twoUp.leftRight,
                                  cols, lastCFI)
    }

    private func handleRelocate(_ event: RelocateEvent) {
        if let fraction = event.fraction, fraction.isFinite { currentFraction = fraction }
        if let cfi = event.cfi { currentCFI = cfi }
        if let label = event.tocLabel { currentTOCLabel = label }
        if let start = event.atStart { atStart = start }
        if let end = event.atEnd { atEnd = end }
        if let page = event.page { currentPage = page }
        if let pages = event.pages { totalPages = pages }
        if let idx = event.sectionIndex { sectionIndex = idx }
        if let count = event.sectionCount { sectionCount = count }
        autoSavePosition()
    }

    private var isCurrentPositionBookmarked: Bool {
        let position: ReadingPosition = .epubCFI(currentCFI ?? "", fraction: currentFraction)
        return bookmarkStore.isPositionBookmarked(fileHash: fileHash, position: position)
    }

    private func toggleBookmark() {
        ReaderHelpers.toggleBookmark(
            store: bookmarkStore, fileURL: fileURL, fileHash: fileHash,
            rawData: rawData, position: .epubCFI(currentCFI ?? "", fraction: currentFraction),
            tocLabel: currentTOCLabel
        )
    }

    private func autoSavePosition() {
        guard let url = fileURL else { return }
        let cfi = currentCFI ?? ""
        guard !cfi.isEmpty || currentFraction > 0 else { return }
        let position: ReadingPosition = .epubCFI(cfi, fraction: currentFraction)
        bookmarkStore.savePosition(
            position, for: url, data: rawData,
            tocLabel: currentTOCLabel, fileHash: fileHash, session: readingSession
        )
    }

    // MARK: - Search

    private func performEPubSearch(_ query: String) {
        search.isSearching = true
        searchResults = []
        search.currentIndex = 0
        webViewProxy.search?(query)
    }

    private func clearEPubSearch() {
        webViewProxy.clearSearch?()
        searchResults = []
        search.currentIndex = 0
        search.isSearching = false
    }

    private func navigateSearchResult(forward: Bool) {
        guard !searchResults.isEmpty else { return }
        if forward {
            search.currentIndex = (search.currentIndex + 1) % searchResults.count
        } else {
            search.currentIndex = (search.currentIndex - 1 + searchResults.count) % searchResults.count
        }
        if let cfi = searchResults[search.currentIndex]["cfi"] {
            webViewProxy.goToSearchResult?(cfi)
        }
    }

    private func dismissSearch() {
        searchDebouncer.cancel()
        search.reset()
        searchResults = []
        webViewProxy.clearSearch?()
    }

    // ePub-specific fast-scroll behavior: foliate-js animates page turns, which
    // becomes visually noisy when the user holds an arrow key. After 4 rapid
    // repeats we ask the bridge to skip animation; on the run reset (count → 0)
    // we re-enable. The other readers don't need this — PDF/Comic image swaps
    // are instant and text-reader page turns animate via manicule.js's own
    // velocity damping. Wired here so FastScrollController stays format-agnostic.
    private func wireFastScrollAnimationSuppression() {
        fastScroll.onCountChanged = { [webViewProxy] count in
            if count == 4 {
                webViewProxy.setAnimated?(false)
            } else if count == 0 {
                webViewProxy.setAnimated?(true)
            }
        }
    }

    // MARK: - Read Aloud (iOS only)

    #if os(iOS) || os(visionOS)
    private var readAloudSectionTextHandler: ((String, Int, Int) -> Void)? {
        { text, sectionIndex, startOffset in
            handleReadAloudSectionText(text, sectionIndex: sectionIndex, startOffset: startOffset)
        }
    }
    private var readAloudSeekHandler: ((Int, Int) -> Void)? {
        { offset, sectionIndex in
            handleReadAloudSeek(offset, sectionIndex: sectionIndex)
        }
    }

    private func toggleReadAloud() {
        if narrationIsActive {
            dismissReadAloud()
            return
        }
        readAloud.claim(for: narrationOwner)
        readAloud.onOwnerReleased = { [weak webViewProxy] in webViewProxy?.stopReadAloud?() }
        // Extract text from current section — will arrive via handleReadAloudSectionText
        webViewProxy.startReadAloud?()
    }

    private func dismissReadAloud() {
        // Capture center anchor before bar disappears (changes WebView height)
        webViewProxy.clearReadAloud?()
        readAloud.dismiss(for: narrationOwner)
        webViewProxy.stopReadAloud?()
        readAloudSectionIndex = -1
    }

    private func setupReadAloudCallbacks() {
        readAloud.onWordRange = { [weak webViewProxy] (range: NSRange) in
            webViewProxy?.highlightReadAloud?(range.location, range.length)
        }
        readAloud.onSectionFinished = { [weak webViewProxy] in
            webViewProxy?.clearReadAloud?()
            webViewProxy?.advanceReadAloudSection?()
        }
        readAloud.onHighlightCleared = { [weak webViewProxy] in
            webViewProxy?.clearReadAloud?()
        }
        readAloud.onPageScrollNeeded = { [weak webViewProxy] offset in
            webViewProxy?.scrollToReadAloudOffset?(offset)
        }
    }

    private func handleReadAloudSectionText(_ text: String, sectionIndex: Int, startOffset: Int = 0) {
        guard ownsNarration, sectionIndex >= 0 else { return }
        readAloudSectionIndex = sectionIndex

        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hasContent = cleaned.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }

        guard hasContent else {
            readAloudEmptySections += 1
            if readAloudEmptySections > 10 {
                dismissReadAloud()
                return
            }
            webViewProxy.advanceReadAloudSection?()
            return
        }

        readAloudEmptySections = 0
        webViewProxy.clearReadAloud?()

        let wasPlaying = readAloud.isPlaying
        let wasActive = narrationIsActive
        let wasNaturalFinish = readAloud.sectionFinishedNaturally
        readAloud.loadText(text, startOffset: startOffset)
        setupReadAloudCallbacks()
        // Auto-play on initial activation, active playback, or section advance
        if wasPlaying || !wasActive || wasNaturalFinish {
            readAloud.play()
        }
    }

    private func handleReadAloudSeek(_ offset: Int, sectionIndex: Int) {
        guard narrationIsActive else { return }
        let now = Date()
        guard now.timeIntervalSince(readAloudLastSeekTime) > 0.3 else { return }
        if sectionIndex == readAloudSectionIndex {
            readAloudLastSeekTime = now
            webViewProxy.clearReadAloud?()
            readAloud.seekAndResume(offset: offset)
        }
    }
    #else
    private var readAloudSectionTextHandler: ((String, Int, Int) -> Void)? { nil }
    private var readAloudSeekHandler: ((Int, Int) -> Void)? { nil }
    #endif

    // MARK: - Settings

    private func adjustFontSize(by delta: Double) {
        let newSize = max(12, min(36, readingPrefs.effective(for: fileHash).fontSize + delta))
        readingPrefs.updatePreference(for: fileHash, apply: { $0.fontSize = newSize }, applyGlobal: { readingPrefs.fontSize = newSize })
    }

    // The bridge picks the matching margin pair from its stored values whenever
    // the resolved column count flips (see applyResolvedColumnCount in bridge.js),
    // so these handlers only need to update the column preference and reading-mode
    // flow — margins flow in via .onChange(of: marginPairs) and openAndInit.
    private func selectAutomatic() {
        readingPrefs.setViewMode(.paginated, twoUp: nil, for: fileHash)
    }

    private func selectSinglePage() {
        readingPrefs.setViewMode(.paginated, twoUp: false, for: fileHash)
    }

    private func selectTwoPage() {
        readingPrefs.setViewMode(.paginated, twoUp: true, for: fileHash)
    }

    private func selectScrolling() {
        readingPrefs.setViewMode(.scrolling, twoUp: nil, for: fileHash)
    }

    /// Restore reading position after a mode switch (scroll/1-up/2-up).
    /// Uses a small delay to let the renderer relayout after the mode change.
    private func restoreCurrentPosition() {
        positionRestoreTask?.cancel()
        let cfi = currentCFI
        let fraction = currentFraction
        positionRestoreTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            if let cfi, !cfi.isEmpty { webViewProxy.goTo?(cfi) }
            else if fraction > 0 { webViewProxy.goToFraction?(fraction) }
        }
    }
}
