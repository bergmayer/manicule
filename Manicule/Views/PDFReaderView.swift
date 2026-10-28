import SwiftUI
import PDFKit

// A newly constructed PDFDocument is transferred once to the main actor.
// It is never accessed again by the loading task.
private struct LoadedPDFDocument: @unchecked Sendable {
    let document: PDFDocument?
}

/// Displays a PDF document with page navigation, thumbnail sidebar, and bookmark toggle.
struct PDFReaderView: View {
    let data: Data
    let fileURL: URL?
    @Environment(\.readingSession) private var readingSession
    let fileHash: String
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    @State private var currentPageIndex: Int = 0
    @State private var pdfDocument: PDFDocument?
    @State private var pageRenderer: PDFPageRenderer?
    @State private var didAttemptLoad: Bool = false
    @State private var pageCount: Int = 0
    @State private var showGoToPage: Bool = false
    @State private var goToPageText: String = ""
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    @State private var showThumbnails: Bool = false
    private var viewMode: ViewMode { readingPrefs.effective(for: fileHash).viewMode }
    private var trimWhitespace: Bool { readingPrefs.effective(for: fileHash).trimWhitespace }
    @State private var originalPDFBounds: [Int: CGRect] = [:]
    @State private var trimmedPages: Set<Int> = []
    @State private var trimTask: Task<Void, Never>?
    private var coverOnRight: Bool { readingPrefs.effective(for: fileHash).coverOnRight }
    @State private var pageEntryTwoUp: Bool?
    @State private var pairingAnchorPage: Int?
    private var twoUpOverride: Bool? { readingPrefs.effective(for: fileHash).twoUp }
    @State private var zoomScale: Double? = nil
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0

    // Slider scrubbing state — defers page navigation until drag ends
    @State private var sliderDragging: Bool = false
    @State private var sliderPageIndex: Int = 0

    @State private var fastScroll = FastScrollController()

    // Search state
    @State private var search = ReaderSearchState()
    private enum SearchResult {
        case text(PDFSelection)
        case imagePage(Int)
    }
    @State private var searchResults: [SearchResult] = []
    @State private var searchDebouncer = SearchDebouncer()
    @State private var searchTask: Task<Void, Never>?

    @FocusState private var isFocused: Bool

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var isPaginated: Bool {
        viewMode == .paginated
    }

    private var effectiveTwoUp: Bool {
        guard isPaginated else { return false }
        return pageEntryTwoUp ?? twoUpOverride ?? ReaderHelpers.defaultTwoUp(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    var body: some View {
        pdfLayout
            #if os(macOS)
            .toolbar { pdfToolbar }
            #endif
            .fullScreenToolbarAutoHide(showChrome: $showChrome)
            .task {
                ReaderHelpers.migrateLegacyIdentity(data: data, currentHash: fileHash)
                readingPrefs.touchLastUsed(for: fileHash)

                await loadDocument()
            }
            .onChange(of: trimWhitespace) { _, enabled in
                if enabled { applyTrimCropBoxes() } else { restoreOriginalCropBoxes() }
            }
            .readerSearchError($search.error)
            .onDisappear {
                autoSavePosition()
                trimTask?.cancel()
                trimTask = nil
                searchDebouncer.cancel()
                clearPdfSearch()
            }
            .readerCommands(ReaderCommandHandlers(
                onToggleViewMode: { if isPaginated { selectScrolling() } else { selectSinglePage() } },
                onBookmark: toggleBookmark,
                onShowSavedPositions: { showBookmarks = true },
                onShowReadingSettings: { showSettings = true },
                onToggleSearch: {
                    search.isShowing.toggle()
                    if !search.isShowing { dismissPdfSearch() }
                },
                onToggleImmersive: { showChrome.toggle() },
                onZoomIn: { zoomScale = min(4.0, (zoomScale ?? 1.0) * 1.25) },
                onZoomOut: {
                    #if os(macOS)
                    zoomScale = max(0.25, (zoomScale ?? 1.0) / 1.25)
                    #else
                    zoomScale = max(0.95, (zoomScale ?? 1.0) / 1.25)
                    #endif
                }
            ))
            .onReaderCommand(.showGoToPage) {
                showGoToPage = true
            }
            .onChange(of: search.query) { _, newQuery in
                clearPdfSearch()
                searchDebouncer.handle(newQuery, perform: performPdfSearch, clear: clearPdfSearch)
            }
            .onChange(of: currentPageIndex) { _, newPage in
                if let anchor = pairingAnchorPage,
                   PageNavigation.normalizedStart(current: anchor, pageCount: pageCount,
                       twoUp: effectiveTwoUp, coverOnRight: coverOnRight) != newPage {
                    pairingAnchorPage = nil
                }
                let normalized = PageNavigation.normalizedStart(
                    current: newPage, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
                if normalized != newPage {
                    currentPageIndex = normalized
                    return
                }
                if trimWhitespace && isPaginated { trimPagesAround(newPage) }
                autoSavePosition()
            }
            .onChange(of: coverOnRight) { _, _ in
                currentPageIndex = PageNavigation.normalizedStart(
                    current: currentPageIndex, pageCount: pageCount, twoUp: effectiveTwoUp,
                    coverOnRight: coverOnRight)
            }
            .onChange(of: effectiveTwoUp) { _, isTwoUp in
                currentPageIndex = PageNavigation.normalizedStart(
                    current: currentPageIndex, pageCount: pageCount, twoUp: isTwoUp, coverOnRight: coverOnRight)
            }
            .alert("Go to Page", isPresented: $showGoToPage) {
                TextField("Page number", text: $goToPageText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Go") {
                    if let page = Int(goToPageText), page >= 1, page <= pageCount {
                        currentPageIndex = page - 1
                    }
                    goToPageText = ""
                }
                Button("Cancel", role: .cancel) { goToPageText = "" }
            } message: {
                Text("Enter a page number (1–\(pageCount))")
            }
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash) { position in
                        if case .pdfPage(let page) = position, (0..<pageCount).contains(page) {
                            currentPageIndex = page
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ReaderSettingsSheet(fileHash: fileHash)
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var pdfLayout: some View {
        HStack(spacing: 0) {
            if showThumbnails {
                PDFThumbnailSidebar(
                    pdfDocument: pdfDocument,
                    pageRenderer: pageRenderer,
                    currentPageIndex: $currentPageIndex,
                    bookmarkedPages: bookmarkedPdfPages
                )
                .frame(width: 160)
                Divider()
            }

            Group {
                if let doc = pdfDocument {
                    pdfContentView(doc: doc)
                        .overlay(alignment: .topTrailing) {
                            if bookmarkedPdfPages.contains(currentPageIndex) {
                                Image(systemName: "bookmark.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                                    .shadow(color: .black.opacity(0.3), radius: 2)
                                    .padding(12)
                            }
                        }
                } else if didAttemptLoad {
                    ContentUnavailableView("Unable to Load PDF",
                        systemImage: "doc.fill",
                        description: Text("The PDF file could not be opened."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .trackViewportSize(width: $viewWidth, height: $viewHeight)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            fastScroll.handle(phase: event.phase)
            previousPage()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            fastScroll.handle(phase: event.phase)
            nextPage()
            return .handled
        }
        .onChange(of: showChrome) { _, _ in
            isFocused = true
        }
        .escapeDismisses(
            searchShowing: { search.isShowing },
            dismissSearch: dismissPdfSearch,
            showChrome: $showChrome
        )
        .background(Color.white.ignoresSafeArea())
        .overlay(alignment: .top) {
            if search.isShowing {
                SearchBarView(
                    query: $search.query,
                    isSearching: $search.isSearching,
                    resultCount: pdfSearchResultCount,
                    currentResult: pdfSearchResultCount == 0 ? 0 : search.currentIndex + 1,
                    onNext: { navigatePdfSearchResult(forward: true) },
                    onPrevious: { navigatePdfSearchResult(forward: false) },
                    onDismiss: { dismissPdfSearch() },
                    minQueryLength: searchDebouncer.minLength
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: search.isShowing)
        #if os(iOS)
        .overlay(alignment: .top) {
            if !showChrome {
                Color.clear
                    .frame(height: 60)
                    .contentShape(Rectangle())
                    .onTapGesture { showChrome = true }
            }
        }
        // iOS overlay chrome (no reflow)
        .overlay(alignment: .top) {
            if showChrome {
                iOSTopBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .overlay(alignment: .bottom) {
            if showChrome {
                pdfBottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbarVisibility(.hidden, for: .automatic)
        .toolbarVisibility(.hidden, for: .navigationBar)
        #else
        .safeAreaInset(edge: .bottom) {
            if showChrome {
                pdfBottomBar
            }
        }
        #endif
        // PDFs render their own backgrounds (often white paper), so we lock
        // the chrome to light regardless of the user's theme — a dark UI
        // around white pages flickers and looks broken.
        .preferredColorScheme(.light)
    }

    // MARK: - Content

    private var currentHighlightSelection: PDFSelection? {
        guard searchResults.indices.contains(search.currentIndex),
              case .text(let selection) = searchResults[search.currentIndex] else { return nil }
        return selection
    }

    @ViewBuilder
    private func pdfContentView(doc: PDFDocument) -> some View {
        #if os(iOS) || os(visionOS)
        if isPaginated && effectiveTwoUp {
            PaginatedPDFContainerView(
                document: doc, currentPage: $currentPageIndex, coverOnRight: coverOnRight,
                scaleFactor: zoomScale, highlightSelection: currentHighlightSelection,
                onToggleChrome: { showChrome.toggle() },
                onNextPage: nextPage, onPreviousPage: previousPage)
        } else {
            nativePDFContent(doc: doc)
        }
        #else
        nativePDFContent(doc: doc)
        #endif
    }

    private func nativePDFContent(doc: PDFDocument) -> some View {
        PDFViewRepresentable(
            pdfDocument: doc,
            currentPageIndex: $currentPageIndex,
            paginated: isPaginated,
            twoUp: effectiveTwoUp,
            coverOnRight: coverOnRight,
            scaleFactor: zoomScale,
            highlightSelection: currentHighlightSelection,
            onToggleChrome: { showChrome.toggle() },
            onNextPage: nextPage,
            onPreviousPage: previousPage
        )
        #if os(macOS)
        // Recreate PDFKit's cached spread layout when pairing changes, including
        // when the current page stays at the cover and no navigation is needed.
        .id(coverOnRight)
        .padding(.leading, isPaginated && effectiveTwoUp && coverOnRight && currentPageIndex == 0 ? viewWidth / 2 : 0)
        .padding(.trailing, isPaginated && effectiveTwoUp && currentPageIndex == pageCount - 1
            && !(coverOnRight && currentPageIndex == 0) ? viewWidth / 2 : 0)
        #endif
        #if os(iOS)
        // PDFKit's page-view-controller and two-up modes are configured only
        // at construction time, so recreate the native view when mode changes.
        .id("pdf-\(isPaginated)-\(effectiveTwoUp)")
        #endif
    }

    // MARK: - iOS Overlay Chrome

    #if os(iOS)
    @ViewBuilder
    private var iOSTopBar: some View {
        HStack {
            if showThumbnails {
                Button("Done") { showThumbnails = false }
            } else if let onClose {
                Button("Close Book", action: onClose)
            }
            Spacer()
            Text(fileURL?.deletingPathExtension().lastPathComponent ?? "")
                .lineLimit(1)
            Spacer()
            Menu {
                Section {
                    ViewModeMenuButtons(
                        onAutomatic: selectAutomatic,
                        onSinglePage: selectSinglePage,
                        onTwoPage: selectTwoPage,
                        onScrolling: selectScrolling,
                        scrollingLabel: "Continuous Scroll"
                    )
                }
                Section {
                    Button { toggleTrim() } label: {
                        Label(trimWhitespace ? "Show Full Page" : "Trim Whitespace",
                              systemImage: trimWhitespace ? "arrow.right.and.line.vertical.and.arrow.left" : "crop")
                    }
                    Button { showThumbnails.toggle() } label: {
                        Label("Thumbnails", systemImage: "sidebar.leading")
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { search.isShowing.toggle(); if !search.isShowing { dismissPdfSearch() } } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                Section {
                    Button { showGoToPage = true } label: { Label("Go to Page", systemImage: "number") }
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
            ReaderChromeBackground().ignoresSafeArea(edges: .top)
        }
    }
    #endif

    /// The page index to display in the bottom bar — uses the scrub target while
    /// the slider is being dragged so the label updates instantly without triggering
    /// expensive page navigation on every intermediate value.
    private var displayedPageIndex: Int {
        PageNavigation.normalizedStart(
            current: sliderDragging ? sliderPageIndex : currentPageIndex,
            pageCount: pageCount,
            twoUp: effectiveTwoUp, coverOnRight: coverOnRight
        )
    }

    @ViewBuilder
    private var pdfBottomBar: some View {
        VStack(spacing: 0) {
            if pageCount > 1 {
                Slider(
                    value: Binding(
                        get: {
                            Double(displayedPageIndex) / Double(max(1, pageCount - 1))
                        },
                        set: { newValue in
                            let page = Int((newValue * Double(pageCount - 1)).rounded())
                            if !sliderDragging {
                                sliderDragging = true
                            }
                            sliderPageIndex = page
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            // Drag ended — commit the page navigation
                            sliderDragging = false
                            currentPageIndex = sliderPageIndex
                        }
                    }
                )
                .padding(.horizontal)
                .padding(.top, 6)

                // Page number preview tooltip while scrubbing
                if sliderDragging {
                    Text("Page \(sliderPageIndex + 1) of \(pageCount)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .transition(.opacity)
                }
            }
            HStack {
                Text(ReaderHelpers.pageLabel(current: displayedPageIndex, total: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))
                    .font(.caption).monospacedDigit()
                ReaderPageField(page: displayedPageIndex + 1, pageCount: pageCount, goToPage: { index in
                    sliderDragging = false
                    currentPageIndex = PageNavigation.normalizedStart(
                        current: index, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
                }, onEditingChanged: { editing in
                    // Keep the page pairing stable until the keyboard finishes closing.
                    let pairing = editing ? effectiveTwoUp : nil
                    DispatchQueue.main.async { pageEntryTwoUp = pairing }
                })
                Spacer()
                let pct = pageCount > 1 ? Int(Double(displayedPageIndex) / Double(pageCount - 1) * 100) : 0
                Text("\(pct)%").font(.caption).monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background { ReaderChromeBackground().ignoresSafeArea(edges: .bottom) }
    }

    // MARK: - Toolbar

    private var currentModeIcon: String {
        ReaderHelpers.viewModeIcon(isPaginated: isPaginated, twoUpOverride: twoUpOverride)
    }

    @ToolbarContentBuilder
    private var pdfToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: previousPage) {
                Label("Previous Page", systemImage: "chevron.left")
            }
            .disabled(!PageNavigation.canGoPrevious(
                current: currentPageIndex, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))

            Button(action: nextPage) {
                Label("Next Page", systemImage: "chevron.right")
            }
            .disabled(!PageNavigation.canGoNext(
                current: currentPageIndex, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                ViewModeMenuButtons(
                    onAutomatic: selectAutomatic,
                    onSinglePage: selectSinglePage,
                    onTwoPage: selectTwoPage,
                    onScrolling: selectScrolling,
                    scrollingLabel: "Continuous Scroll"
                )
            } label: {
                Label("View Mode", systemImage: currentModeIcon)
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { toggleTrim() } label: {
                Label(trimWhitespace ? "Show Full Page" : "Trim Whitespace",
                      systemImage: trimWhitespace ? "arrow.right.and.line.vertical.and.arrow.left" : "crop")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { showThumbnails.toggle() } label: {
                Label("Thumbnails", systemImage: "sidebar.leading")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { toggleBookmark() } label: {
                Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { search.isShowing.toggle(); if !search.isShowing { dismissPdfSearch() } } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { showSettings = true } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
        }
    }

    private var bookmarkedPdfPages: Set<Int> {
        Set(bookmarkStore.bookmarks(for: fileHash).compactMap { entry -> Int? in
            if case .pdfPage(let page) = entry.position { return page }
            return nil
        })
    }

    private var isCurrentPositionBookmarked: Bool {
        return bookmarkStore.isPositionBookmarked(fileHash: fileHash, position: .pdfPage(currentPageIndex))
    }

    private var pageLabel: String {
        ReaderHelpers.pageLabel(current: currentPageIndex, total: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
    }

    private func previousPage() {
        let newIndex = PageNavigation.previous(
            current: currentPageIndex, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
        if newIndex != currentPageIndex { currentPageIndex = newIndex }
    }

    private func nextPage() {
        let newIndex = PageNavigation.next(
            current: currentPageIndex, pageCount: pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
        if newIndex != currentPageIndex { currentPageIndex = newIndex }
    }

    private func loadDocument() async {
        // Render the same immutable snapshot used for the document hash.
        // Reopening the URL could silently display an externally replaced file.
        let sourceData = data
        let loaded = await Task.detached(priority: .userInitiated) {
            LoadedPDFDocument(document: PDFDocument(data: sourceData))
        }.value
        guard !Task.isCancelled else { return }
        didAttemptLoad = true
        guard let doc = loaded.document else { return }

        pageRenderer = PDFPageRenderer(data: sourceData, fileHash: fileHash)
        pdfDocument = doc
        pageCount = doc.pageCount

        // Restore position: auto-saved first, then manual bookmarks
        if let page = ReaderHelpers.restorePagePosition(store: bookmarkStore, fileHash: fileHash, pageCount: doc.pageCount, extract: {
            if case .pdfPage(let p) = $0 { return p }; return nil
        }) {
            currentPageIndex = page
        }

        if trimWhitespace {
            applyTrimCropBoxes()
        }
    }

    // MARK: - Search

    private var pdfSearchResultCount: Int { searchResults.count }

    private func performPdfSearch(_ query: String) {
        clearPdfSearch()
        guard let doc = pdfDocument, let renderer = pageRenderer else { return }
        search.isSearching = true
        searchTask = Task {
            do {
                let matches = try await renderer.search(query)
                try Task.checkCancellation()
                searchResults = matches.compactMap { ranges in
                    let selection = PDFSelection(document: doc)
                    for match in ranges {
                        if let part = doc.page(at: match.pageIndex)?.selection(for: match.range) {
                            selection.add(part)
                        }
                    }
                    return selection.pages.isEmpty ? nil : .text(selection)
                }
                // Image-only documents still get OCR when the text layer has no matches.
                if searchResults.isEmpty {
                    for index in 0..<doc.pageCount {
                        try Task.checkCancellation()
                        let image = try await renderer.ocrImage(at: index)
                        let contains = try await OCRService.shared.pageContains(
                            image: image, fileHash: fileHash, pageIndex: index, query: query)
                        try Task.checkCancellation()
                        if contains { searchResults.append(.imagePage(index)) }
                    }
                }
                search.isSearching = false
                showPdfSearchResult()
            } catch is CancellationError {
                // The replacing operation owns the UI now.
            } catch {
                guard !Task.isCancelled else { return }
                search.isSearching = false
                search.error = "Search could not finish. Results may be incomplete. \(error.localizedDescription)"
            }
        }
    }

    private func clearPdfSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        search.currentIndex = 0
        search.isSearching = false
        search.error = nil
    }

    private func navigatePdfSearchResult(forward: Bool) {
        let count = pdfSearchResultCount
        guard count > 0 else { return }
        if forward {
            search.currentIndex = (search.currentIndex + 1) % count
        } else {
            search.currentIndex = (search.currentIndex - 1 + count) % count
        }
        showPdfSearchResult()
    }

    private func showPdfSearchResult() {
        guard searchResults.indices.contains(search.currentIndex) else { return }
        switch searchResults[search.currentIndex] {
        case .imagePage(let page): currentPageIndex = page
        case .text(let selection): navigateToSelection(selection)
        }
    }

    private func navigateToSelection(_ selection: PDFSelection) {
        guard let page = selection.pages.first,
              let doc = pdfDocument else { return }
        if let pageIndex = (0..<doc.pageCount).first(where: { doc.page(at: $0) == page }) {
            currentPageIndex = pageIndex
        }
    }

    private func dismissPdfSearch() {
        searchDebouncer.cancel()
        clearPdfSearch()
        search.reset()
    }

    private func toggleBookmark() {
        ReaderHelpers.toggleBookmark(
            store: bookmarkStore, fileURL: fileURL, fileHash: fileHash,
            rawData: data, position: .pdfPage(currentPageIndex)
        )
    }

    private func autoSavePosition() {
        guard let url = fileURL else { return }
        guard pdfDocument != nil else { return }
        let position: ReadingPosition = .pdfPage(currentPageIndex)
        bookmarkStore.savePosition(position, for: url, data: data, fileHash: fileHash, session: readingSession)
    }


    private func selectAutomatic() {
        pairingAnchorPage = nil
        readingPrefs.setViewMode(.paginated, twoUp: nil, for: fileHash)
    }

    private func selectSinglePage() {
        pairingAnchorPage = nil
        readingPrefs.setViewMode(.paginated, twoUp: false, for: fileHash)
    }

    private func selectTwoPage() {
        let anchor = pairingAnchorPage ?? currentPageIndex
        let shifted = effectiveTwoUp ? !coverOnRight : coverOnRight
        pairingAnchorPage = anchor
        readingPrefs.setViewMode(.paginated, twoUp: true, coverOnRight: shifted, for: fileHash)
        currentPageIndex = PageNavigation.normalizedStart(
            current: anchor, pageCount: pageCount, twoUp: true, coverOnRight: shifted)
    }

    private func selectScrolling() {
        pairingAnchorPage = nil
        readingPrefs.setViewMode(.scrolling, twoUp: nil, for: fileHash)
    }

    private func toggleTrim() {
        let enabled = !trimWhitespace
        readingPrefs.updatePreference(for: fileHash, apply: { $0.trimWhitespace = enabled },
                                      applyGlobal: { readingPrefs.trimWhitespace = enabled })
    }

    /// Starts per-page whitespace trimming, processing the current page first
    /// then expanding outward. Uses a single background PDFDocument.
    /// In scrolling mode, trims all pages upfront to avoid layout jumps.
    private func applyTrimCropBoxes() {
        trimTask?.cancel()
        trimmedPages = []
        startTrimFrom(currentPageIndex, allPages: !isPaginated)
    }

    /// Ensures pages around `center` are trimmed. If the background task already
    /// covers them, this is a no-op. Otherwise it starts a new pass.
    private func trimPagesAround(_ center: Int) {
        let radius = 2
        let count = pdfDocument?.pageCount ?? 0
        guard count > 0 else { return }
        let lo = max(0, center - radius)
        let hi = min(count - 1, center + radius)
        guard lo <= hi else { return }
        let needed = (lo...hi).contains(where: { !trimmedPages.contains($0) })
        guard needed else { return }
        startTrimFrom(center)
    }

    /// Launches a single background task that creates one PDFDocument and processes
    /// pages outward from `center`, applying crop boxes as each page completes.
    /// When `allPages` is true (scrolling mode), computes all crop boxes first,
    /// then applies them in a single batch to avoid layout thrashing.
    private func startTrimFrom(_ center: Int, allPages: Bool = false) {
        guard let doc = pdfDocument, let pageRenderer else { return }
        let count = doc.pageCount
        guard count > 0 else { return }

        // Save original bounds for all pages on first trim
        if originalPDFBounds.isEmpty {
            for i in 0..<count {
                if let page = doc.page(at: i) {
                    originalPDFBounds[i] = page.bounds(for: .cropBox)
                }
            }
        }

        let pageOrder = PageNavigation.nearestFirst(center: center, pageCount: count)
            .filter { !trimmedPages.contains($0) }
        guard !pageOrder.isEmpty else { return }

        trimTask?.cancel()
        trimTask = Task {
            var cropBoxes: [Int: CGRect] = [:]
            for i in pageOrder {
                guard !Task.isCancelled else { return }
                let box = await pageRenderer.cropBox(at: i)
                // Cancellation while awaiting detection must not reapply a crop
                // after the user has restored the original page bounds.
                guard !Task.isCancelled else { return }
                cropBoxes[i] = box
                if !allPages {
                    if let box { doc.page(at: i)?.setBounds(box, for: .cropBox) }
                    trimmedPages.insert(i)
                }
            }
            if allPages {
                for (i, box) in cropBoxes {
                    doc.page(at: i)?.setBounds(box, for: .cropBox)
                }
                trimmedPages.formUnion(pageOrder)
            }
        }
    }

    /// Restores original crop boxes when trim is disabled.
    private func restoreOriginalCropBoxes() {
        trimTask?.cancel()
        trimTask = nil
        guard let doc = pdfDocument else { return }
        for (i, bounds) in originalPDFBounds {
            doc.page(at: i)?.setBounds(bounds, for: .cropBox)
        }
        originalPDFBounds = [:]
        trimmedPages = []
    }
}

// MARK: - PDF Thumbnail Sidebar

private struct PDFThumbnailSidebar: View {
    let pdfDocument: PDFDocument?
    let pageRenderer: PDFPageRenderer?
    @Binding var currentPageIndex: Int
    var bookmarkedPages: Set<Int> = []

    private var pageCount: Int { pdfDocument?.pageCount ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let doc = pdfDocument, let pageRenderer {
                        ForEach(0..<doc.pageCount, id: \.self) { index in
                            PDFPageThumbnail(document: doc, renderer: pageRenderer, pageIndex: index, isSelected: index == currentPageIndex, isBookmarked: bookmarkedPages.contains(index))
                                .id(index)
                                .onTapGesture {
                                    currentPageIndex = index
                                }
                        }
                    }
                }
                .padding(8)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                guard currentPageIndex > 0 else { return .ignored }
                currentPageIndex -= 1
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard currentPageIndex < pageCount - 1 else { return .ignored }
                currentPageIndex += 1
                return .handled
            }
            .navigationTitle("Pages")
            .onChange(of: currentPageIndex) { _, newValue in
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .task {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
        }
    }
}

private struct PDFPageThumbnail: View {
    let document: PDFDocument
    let renderer: PDFPageRenderer
    let pageIndex: Int
    let isSelected: Bool
    var isBookmarked: Bool = false

    @State private var thumbnail: CGImage?

    private var aspect: CGFloat {
        guard let page = document.page(at: pageIndex) else { return 0.75 }
        let bounds = page.bounds(for: .mediaBox)
        return bounds.width / bounds.height
    }

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    // Placeholder with correct aspect ratio — shown instantly
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.12))
                        .aspectRatio(aspect, contentMode: .fit)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .padding(4)
                }
            }
            .border(isSelected ? Color.accentColor : Color.clear, width: 2)
            .shadow(radius: isSelected ? 2 : 0)

            Text("\(pageIndex + 1)")
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .task(id: pageIndex) {
            let result = await renderer.thumbnail(at: pageIndex, width: 160)
            if !Task.isCancelled {
                thumbnail = result
            }
        }
    }
}
