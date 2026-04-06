import SwiftUI
import AVFoundation

/// Displays an ePub book using foliate-js web components with built-in pagination,
/// touch handling, and CFI-based navigation.
struct EPubReaderView: View {
    let book: EPubBook
    let fileURL: URL?
    let rawData: Data
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    private let fileHash: String?

    init(book: EPubBook, fileURL: URL?, rawData: Data, showChrome: Binding<Bool>, onClose: (() -> Void)? = nil) {
        self.book = book
        self.fileURL = fileURL
        self.rawData = rawData
        self._showChrome = showChrome
        self.onClose = onClose
        self.fileHash = FileHasher.hash(data: rawData)
    }

    // Navigation state from foliate-js relocate events
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
    @State private var viewMode: ViewMode = .paginated
    @State private var twoUpOverride: Bool?
    @State private var viewWidth: CGFloat = 0
    @State private var webViewProxy = WebViewProxy()
    @State private var bridgeReady = false
    @State private var bookReady = false

    // Key repeat quick vanish state
    @State private var keyRepeatCount: Int = 0
    @State private var fastScrollTimer: Timer?

    // Read-aloud state (iOS only)
    #if os(iOS) || os(visionOS)
    private let readAloud = ReadAloudController.shared
    @State private var readAloudSectionIndex: Int = -1
    @State private var readAloudEmptySections: Int = 0
    @State private var readAloudLastSeekTime: Date = .distantPast
    #endif

    // Search state
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [[String: String]] = []
    @State private var currentSearchIndex = 0
    @State private var isSearching = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var isPaginated: Bool {
        viewMode == .paginated
    }

    /// Stable temp file URL derived from the file hash. Written to disk in `.task`.
    private var bookTempURL: URL {
        let hash = fileHash ?? "unknown"
        return FileManager.default.temporaryDirectory.appendingPathComponent("raedad-\(hash).epub")
    }

    private var effectiveTwoUp: Bool {
        isPaginated && twoUpOverride == true
    }

    private var activeMargins: MarginSettings {
        let effective = readingPrefs.effective(for: fileHash)
        return effectiveTwoUp ? effective.marginsTwoUp : effective.marginsOneUp
    }

    var body: some View {
        epubLayoutWithToolbar
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash ?? "") { position in
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
            .onChange(of: activeMargins) { _, newMargins in
                webViewProxy.setMargins?(newMargins.topBottom, newMargins.leftRight)
            }
            .onChange(of: effectiveTwoUp) { _, newValue in
                webViewProxy.setColumnCount?(newValue ? 2 : 1)
                let m = newValue ? readingPrefs.effective(for: fileHash).marginsTwoUp
                                 : readingPrefs.effective(for: fileHash).marginsOneUp
                webViewProxy.setMargins?(m.topBottom, m.leftRight)
            }
    }

    @ViewBuilder
    private var epubLayoutWithToolbar: some View {
        epubLayoutWithNotifications
            #if os(macOS)
            .toolbar { epubToolbar }
            #endif
            .fullScreenToolbarAutoHide(showChrome: $showChrome)
            .onChange(of: showTOC) { _, _ in
                webViewProxy.refocus?()
            }
            .task {
                readingPrefs.touchLastUsed(for: fileHash)
                let eff = readingPrefs.effective(for: fileHash)
                viewMode = eff.viewMode
                twoUpOverride = eff.twoUp ?? ReaderHelpers.defaultTwoUpForOrientation()
                let tempFile = bookTempURL
                if !FileManager.default.fileExists(atPath: tempFile.path) {
                    try? rawData.write(to: tempFile)
                }
                bookReady = true
            }
            .onDisappear {
                autoSavePosition()
                #if os(iOS) || os(visionOS)
                if readAloud.isActive { readAloud.dismiss() }
                #endif
            }
    }

    @ViewBuilder
    private var epubLayoutWithNotifications: some View {
        epubLayout
            .onReceive(NotificationCenter.default.publisher(for: .toggleTableOfContents)) { _ in
                withAnimation { showTOC.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showReadingSettings)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarkPosition)) { _ in
                toggleBookmark()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleViewMode)) { _ in
                if isPaginated { selectScrolling() } else { selectSinglePage() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
                adjustFontSize(by: 1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
                adjustFontSize(by: -1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleImmersive)) { _ in
                showChrome.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSavedPositions)) { _ in
                showBookmarks = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextChapter)) { _ in
                goToNextChapter()
            }
            .onReceive(NotificationCenter.default.publisher(for: .previousChapter)) { _ in
                goToPreviousChapter()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
                showSearch.toggle()
                if !showSearch { dismissSearch() }
            }
            #if os(iOS) || os(visionOS)
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadAloud)) { _ in
                toggleReadAloud()
            }
            #endif
            .onChange(of: searchQuery) { _, newQuery in
                performEPubSearch(newQuery)
            }
    }

    @ViewBuilder
    private var epubLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showTOC && sizeClass != .compact {
                    TableOfContentsView(
                        entries: book.tableOfContents,
                        currentTOCLabel: currentTOCLabel,
                        bookmarkTOCLabels: Set(bookmarkStore.bookmarks(for: fileHash ?? "").compactMap(\.tocLabel)),
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
                    .transition(.move(edge: .leading))
                    Divider()
                }
                GeometryReader { geometry in
                    epubContent
                        .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                            viewWidth = newWidth
                        }
                }
            }
        }
        .navigationTitle(book.metadata.title)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            handleKeyRepeat(event.phase)
            goBack()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            handleKeyRepeat(event.phase)
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
                    bookmarkTOCLabels: Set(bookmarkStore.bookmarks(for: fileHash ?? "").compactMap(\.tocLabel)),
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
        .onKeyPress(.escape) {
            if showSearch { dismissSearch(); return .handled }
            #if os(iOS)
            if !showChrome {
                showChrome = true
                return .handled
            }
            #endif
            return .ignored
        }
        .overlay(alignment: .top) {
            if showSearch {
                SearchBarView(
                    query: $searchQuery,
                    isSearching: $isSearching,
                    resultCount: searchResults.count,
                    currentResult: searchResults.isEmpty ? 0 : currentSearchIndex + 1,
                    onNext: { navigateSearchResult(forward: true) },
                    onPrevious: { navigateSearchResult(forward: false) },
                    onDismiss: { dismissSearch() }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSearch)
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
                if readAloud.isActive {
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
        if bookReady {
            WebViewRepresentable(
                content: WebViewContent(
                    fileURL: URL(fileURLWithPath: "/"),
                    baseURL: URL(fileURLWithPath: "/"),
                    scrollFraction: nil,
                    fragment: nil,
                    cssOverride: nil,
                    paginated: isPaginated,
                    isEPub: true,
                    bookFileURL: bookTempURL
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
                    if done { isSearching = false }
                    if !results.isEmpty && currentSearchIndex >= results.count {
                        currentSearchIndex = 0
                    }
                },
                onReadAloudSectionText: readAloudSectionTextHandler,
                onReadAloudSeek: readAloudSeekHandler
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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    private var currentModeIcon: String {
        ReaderHelpers.viewModeIcon(isPaginated: isPaginated, isTwoUp: effectiveTwoUp)
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
                Button { selectSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
                Button { selectTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
                Button { selectScrolling() } label: { Label("Scrolling", systemImage: "scroll") }
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
            Button { showSearch.toggle(); if !showSearch { dismissSearch() } } label: {
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
            if let onClose {
                if readAloud.isActive {
                    Button {
                        readAloud.dismiss()
                    } label: {
                        Label("Done", systemImage: "speaker.wave.2.fill")
                    }
                } else {
                    Button("Done", action: onClose)
                }
            }
            Spacer()
            Text(book.metadata.title)
                .lineLimit(1)
            Spacer()
            Menu {
                Section {
                    Button { selectSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
                    Button { selectTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
                    Button { selectScrolling() } label: { Label("Scrolling", systemImage: "scroll") }
                }
                Section {
                    if !book.tableOfContents.isEmpty {
                        Button { withAnimation { showTOC.toggle() } } label: {
                            Label("Table of Contents", systemImage: showTOC ? "list.bullet.indent" : "list.bullet")
                        }
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { showSearch.toggle(); if !showSearch { dismissSearch() } } label: {
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
                        Label(readAloud.isActive ? "Stop Read Aloud" : "Read Aloud",
                              systemImage: readAloud.isActive ? "speaker.slash" : "speaker.wave.2")
                    }
                }
                Section {
                    Button { showSettings = true } label: { Label("Reading Settings", systemImage: "textformat.size") }
                    Button { showBookmarks = true } label: { Label("Go to Bookmark...", systemImage: "bookmark") }
                }
            } label: {
                Label("Menu", systemImage: "ellipsis.circle")
            }
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
        let margins = activeMargins
        let cols = effectiveTwoUp ? 2 : nil as Int?

        // Load position for restoration: auto-saved position first, then manual bookmarks
        let lastCFI: String?
        if let hash = fileHash, let autoSaved = bookmarkStore.savedPosition(for: hash),
           case .epubCFI(let cfi, _) = autoSaved.position, !cfi.isEmpty {
            lastCFI = cfi
        } else if let mostRecent = bookmarkStore.bookmarks(for: fileHash ?? "").first {
            switch mostRecent.position {
            case .epubCFI(let cfi, _) where !cfi.isEmpty:
                lastCFI = cfi
            default:
                lastCFI = nil
            }
        } else {
            lastCFI = nil
        }

        // Open book, apply settings, and init navigation in one chained call
        webViewProxy.openAndInit?(flow, css, margins.topBottom, margins.leftRight, cols, lastCFI)
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
        guard let hash = fileHash else { return false }
        let position: ReadingPosition = .epubCFI(currentCFI ?? "", fraction: currentFraction)
        return bookmarkStore.isPositionBookmarked(fileHash: hash, position: position)
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
        bookmarkStore.savePosition(position, for: url, data: rawData, tocLabel: currentTOCLabel)
    }

    // MARK: - Search

    private func performEPubSearch(_ query: String) {
        guard !query.isEmpty else {
            webViewProxy.clearSearch?()
            searchResults = []
            currentSearchIndex = 0
            isSearching = false
            return
        }
        isSearching = true
        searchResults = []
        currentSearchIndex = 0
        webViewProxy.search?(query)
    }

    private func navigateSearchResult(forward: Bool) {
        guard !searchResults.isEmpty else { return }
        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        }
        if let cfi = searchResults[currentSearchIndex]["cfi"] {
            webViewProxy.goToSearchResult?(cfi)
        }
    }

    private func dismissSearch() {
        showSearch = false
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
        isSearching = false
        webViewProxy.clearSearch?()
    }

    // MARK: - Key repeat quick vanish

    private func handleKeyRepeat(_ phase: KeyPress.Phases) {
        if phase == .down {
            keyRepeatCount = 0
        }
        keyRepeatCount += 1
        if keyRepeatCount == 4 {
            webViewProxy.setAnimated?(false)
        }
        resetFastScrollTimer()
    }

    private func resetFastScrollTimer() {
        fastScrollTimer?.invalidate()
        fastScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                keyRepeatCount = 0
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
        if readAloud.isActive {
            dismissReadAloud()
            return
        }
        // Extract text from current section — will arrive via handleReadAloudSectionText
        webViewProxy.startReadAloud?()
    }

    private func dismissReadAloud() {
        // Capture center anchor before bar disappears (changes WebView height)
        webViewProxy.clearReadAloud?()
        readAloud.dismiss()
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
        guard sectionIndex >= 0 else { return }
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
        let wasActive = readAloud.isActive
        let wasNaturalFinish = readAloud.sectionFinishedNaturally
        readAloud.loadText(text, startOffset: startOffset)
        setupReadAloudCallbacks()
        // Auto-play on initial activation, active playback, or section advance
        if wasPlaying || !wasActive || wasNaturalFinish {
            readAloud.play()
        }
    }

    private func handleReadAloudSeek(_ offset: Int, sectionIndex: Int) {
        guard readAloud.isActive else { return }
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

    private func selectSinglePage() {
        let wasScrolling = !isPaginated
        viewMode = .paginated
        twoUpOverride = false
        if wasScrolling { webViewProxy.setFlow?("paginated") }
        webViewProxy.setColumnCount?(1)
        let m = readingPrefs.effective(for: fileHash).marginsOneUp
        webViewProxy.setMargins?(m.topBottom, m.leftRight)
        restoreCurrentPosition()
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .paginated; $0.twoUp = false }, applyGlobal: { readingPrefs.viewMode = .paginated })
    }

    private func selectTwoPage() {
        let wasScrolling = !isPaginated
        viewMode = .paginated
        twoUpOverride = true
        if wasScrolling { webViewProxy.setFlow?("paginated") }
        webViewProxy.setColumnCount?(2)
        let m = readingPrefs.effective(for: fileHash).marginsTwoUp
        webViewProxy.setMargins?(m.topBottom, m.leftRight)
        restoreCurrentPosition()
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .paginated; $0.twoUp = true }, applyGlobal: { readingPrefs.viewMode = .paginated })
    }

    private func selectScrolling() {
        viewMode = .scrolling
        webViewProxy.setFlow?("scrolled")
        let m = readingPrefs.effective(for: fileHash).marginsOneUp
        webViewProxy.setMargins?(m.topBottom, m.leftRight)
        restoreCurrentPosition()
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .scrolling; $0.twoUp = nil }, applyGlobal: { readingPrefs.viewMode = .scrolling })
    }

    /// Restore reading position after a mode switch (scroll/1-up/2-up).
    /// Uses a small delay to let the renderer relayout after the mode change.
    private func restoreCurrentPosition() {
        if let cfi = currentCFI, !cfi.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                webViewProxy.goTo?(cfi)
            }
        } else if currentFraction > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                webViewProxy.goToFraction?(currentFraction)
            }
        }
    }
}
