import SwiftUI

/// Displays CBZ comic pages with arrow navigation, thumbnail sidebar, and bookmark toggle.
/// Supports paginated (single/two-page) and scrolling (vertical strip) view modes.
struct ComicReaderView: View {
    let archive: ComicArchive
    let fileURL: URL?
    let rawData: Data
    @Environment(\.readingSession) private var readingSession
    let fileHash: String
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    @State private var currentPage: Int = 0
    @State private var readingDirection: ComicArchive.ReadingDirection = .leftToRight
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    @State private var showThumbnails: Bool = false
    private var coverOnRight: Bool { readingPrefs.effective(for: fileHash).coverOnRight }
    @State private var pageEntryTwoUp: Bool?
    @State private var pairingAnchorPage: Int?
    private var twoUpOverride: Bool? { readingPrefs.effective(for: fileHash).twoUp }
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    private var viewMode: ViewMode { readingPrefs.effective(for: fileHash).viewMode }
    private var trimWhitespace: Bool { readingPrefs.effective(for: fileHash).trimWhitespace }
    @State private var zoomScale: Double = 1.0
    @State private var navigatingForward: Bool = true

    // Slider scrubbing state — defers page navigation until drag ends
    @State private var sliderDragging: Bool = false
    @State private var sliderPageIndex: Int = 0

    @State private var fastScroll = FastScrollController()

    // Search state
    @State private var search = ReaderSearchState()
    @State private var searchMatchPages: [Int] = []
    @State private var searchDebouncer = SearchDebouncer()
    @State private var ocrSearchTask: Task<Void, Never>?
    @State private var ocrPagesScanned = 0

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
        comicLayoutWithNotifications
            .task {
                ReaderHelpers.migrateLegacyIdentity(data: rawData, currentHash: fileHash)
                readingPrefs.touchLastUsed(for: fileHash)
                restorePosition()
            }
            .readerSearchError($search.error)
            .onDisappear {
                autoSavePosition()
                searchDebouncer.cancel()
                clearComicSearch()
            }
            .onChange(of: currentPage) { _, newPage in
                if let anchor = pairingAnchorPage,
                   PageNavigation.normalizedStart(current: anchor, pageCount: archive.pageCount,
                       twoUp: effectiveTwoUp, coverOnRight: coverOnRight) != newPage {
                    pairingAnchorPage = nil
                }
                let normalized = PageNavigation.normalizedStart(
                    current: newPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
                if normalized != newPage {
                    currentPage = normalized
                    return
                }
                autoSavePosition()
            }
            .onChange(of: coverOnRight) { _, _ in
                currentPage = PageNavigation.normalizedStart(
                    current: currentPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp,
                    coverOnRight: coverOnRight)
            }
            .onChange(of: effectiveTwoUp) { _, isTwoUp in
                currentPage = PageNavigation.normalizedStart(
                    current: currentPage, pageCount: archive.pageCount, twoUp: isTwoUp, coverOnRight: coverOnRight)
            }
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash) { position in
                        if case .comicPage(let page) = position, archive.pages.indices.contains(page) {
                            currentPage = page
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ReaderSettingsSheet(fileHash: fileHash)
            }
    }

    @ViewBuilder
    private var comicLayoutWithNotifications: some View {
        comicLayout
            .readerCommands(ReaderCommandHandlers(
                onToggleViewMode: { if isPaginated { selectScrolling() } else { selectSinglePage() } },
                onBookmark: toggleBookmark,
                onShowSavedPositions: { showBookmarks = true },
                onShowReadingSettings: { showSettings = true },
                onToggleSearch: {
                    search.isShowing.toggle()
                    if !search.isShowing { dismissComicSearch() }
                },
                onToggleImmersive: { showChrome.toggle() },
                onZoomIn: { zoomScale = min(5.0, zoomScale * 1.25) },
                onZoomOut: { zoomScale = max(0.25, zoomScale / 1.25) }
            ))
            .onReaderCommand(.toggleReadingDirection) {
                readingDirection = readingDirection == .leftToRight ? .rightToLeft : .leftToRight
            }
            .onChange(of: search.query) { _, newQuery in
                clearComicSearch()
                searchDebouncer.handle(newQuery, perform: performComicSearch, clear: clearComicSearch)
            }
    }

    @ViewBuilder
    private var comicLayout: some View {
        HStack(spacing: 0) {
            if showThumbnails {
                ComicThumbnailSidebar(
                    archive: archive,
                    currentPage: $currentPage,
                    bookmarkedPages: bookmarkedComicPages
                )
                .frame(width: 160)
                Divider()
            }

            Group {
                if isPaginated {
                    paginatedContent
                } else {
                    scrollingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .topTrailing) {
                if bookmarkedComicPages.contains(currentPage) {
                    Image(systemName: "bookmark.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(12)
                }
            }
            .trackViewportSize(width: $viewWidth, height: $viewHeight)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            fastScroll.handle(phase: event.phase)
            previousPage(animated: fastScroll.count < 4)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            fastScroll.handle(phase: event.phase)
            nextPage(animated: fastScroll.count < 4)
            return .handled
        }
        .onChange(of: showChrome) { _, _ in
            isFocused = true
        }
        #if os(macOS)
        .toolbar { comicToolbar }
        #endif
        .fullScreenToolbarAutoHide(showChrome: $showChrome)
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .automatic)
        .toolbarVisibility(.hidden, for: .navigationBar)
        // Comics render full-bleed images on a black background, so the chrome
        // is locked to dark regardless of the user's theme — a light UI around
        // dark pages is jarring and breaks immersion.
        .preferredColorScheme(.dark)
        #endif
        .escapeDismisses(
            searchShowing: { search.isShowing },
            dismissSearch: dismissComicSearch,
            showChrome: $showChrome
        )
        .overlay(alignment: .top) {
            if search.isShowing {
                SearchBarView(
                    query: $search.query,
                    isSearching: $search.isSearching,
                    resultCount: searchMatchPages.count,
                    currentResult: searchMatchPages.isEmpty ? 0 : search.currentIndex + 1,
                    onNext: { navigateComicSearchResult(forward: true) },
                    onPrevious: { navigateComicSearchResult(forward: false) },
                    onDismiss: { dismissComicSearch() },
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
                comicBottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            if showChrome {
                comicBottomBar
            }
        }
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
                              systemImage: trimWhitespace ? "arrow.up.left.and.arrow.down.right" : "crop")
                    }
                    Button { showThumbnails.toggle() } label: {
                        Label("Thumbnails", systemImage: "sidebar.leading")
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { search.isShowing.toggle(); if !search.isShowing { dismissComicSearch() } } label: {
                        Label("Search", systemImage: "magnifyingglass")
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
            ReaderChromeBackground().ignoresSafeArea(edges: .top)
        }
    }
    #endif

    private var displayedComicPage: Int {
        PageNavigation.normalizedStart(
            current: sliderDragging ? sliderPageIndex : currentPage,
            pageCount: archive.pageCount,
            twoUp: effectiveTwoUp, coverOnRight: coverOnRight
        )
    }

    @ViewBuilder
    private var comicBottomBar: some View {
        VStack(spacing: 0) {
            if archive.pageCount > 1 {
                Slider(
                    value: Binding(
                        get: {
                            Double(displayedComicPage) / Double(max(1, archive.pageCount - 1))
                        },
                        set: { newValue in
                            let page = Int((newValue * Double(archive.pageCount - 1)).rounded())
                            if !sliderDragging {
                                sliderDragging = true
                            }
                            sliderPageIndex = page
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            sliderDragging = false
                            currentPage = sliderPageIndex
                        }
                    }
                )
                .padding(.horizontal)
                .padding(.top, 6)

                if sliderDragging {
                    Text("Page \(sliderPageIndex + 1) of \(archive.pageCount)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .transition(.opacity)
                }
            }
            HStack {
                Text(ReaderHelpers.pageLabel(current: displayedComicPage, total: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))
                    .font(.caption).monospacedDigit()
                ReaderPageField(page: displayedComicPage + 1, pageCount: archive.pageCount, goToPage: { index in
                    sliderDragging = false
                    currentPage = PageNavigation.normalizedStart(
                        current: index, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
                }, onEditingChanged: { editing in
                    // Keep the page pairing stable until the keyboard finishes closing.
                    let pairing = editing ? effectiveTwoUp : nil
                    DispatchQueue.main.async { pageEntryTwoUp = pairing }
                })
                Spacer()
                let pct = archive.pageCount > 1 ? Int(Double(displayedComicPage) / Double(archive.pageCount - 1) * 100) : 0
                Text("\(pct)%").font(.caption).monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background { ReaderChromeBackground().ignoresSafeArea(edges: .bottom) }
    }

    // MARK: - Paginated Content

    @ViewBuilder
    private var paginatedContent: some View {
        #if os(iOS) || os(visionOS)
        PaginatedComicContainerView(
            pages: archive.pages,
            currentPage: $currentPage,
            twoUp: effectiveTwoUp,
            coverOnRight: coverOnRight,
            readingDirection: readingDirection,
            trimWhitespace: trimWhitespace,
            onToggleChrome: { showChrome.toggle() }
        )
        #else
        Group {
            if effectiveTwoUp {
                twoUpContent_macOS
            } else {
                singlePageContent_macOS
            }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var singlePageContent_macOS: some View {
        let forwardEdge: Edge = navigatingForward ? .trailing : .leading
        let backEdge: Edge = navigatingForward ? .leading : .trailing

        ZoomableComicPageView(
            imageURL: archive.pages[currentPage],
            viewSize: CGSize(width: viewWidth, height: viewHeight),
            trimWhitespace: trimWhitespace,
            onTapZone: { zone in
                switch zone {
                case .left: previousPage()
                case .right: nextPage()
                case .center: showChrome.toggle()
                }
            },
            onNext: { nextPage(animated: true) },
            onPrevious: { previousPage(animated: true) },
            zoomScale: $zoomScale
        )
        .id(currentPage)
        .transition(.asymmetric(
            insertion: .move(edge: forwardEdge),
            removal: .move(edge: backEdge)
        ))
    }

    @ViewBuilder
    private var twoUpContent_macOS: some View {
        let forwardEdge: Edge = navigatingForward ? .trailing : .leading
        let backEdge: Edge = navigatingForward ? .leading : .trailing

        twoPageSpread
            .transition(.asymmetric(
                insertion: .move(edge: forwardEdge),
                removal: .move(edge: backEdge)
            ))
            .gesture(tapGesture)
            .gesture(swipeGesture)
            .overlay {
                ScrollWheelOverlay(
                    onNext: { nextPage(animated: true) },
                    onPrevious: { previousPage(animated: true) }
                )
            }
    }

    /// Tap gesture: left 1/3 = previous, right 1/3 = next, center 1/3 = toggle chrome
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let x = value.location.x
                if x < viewWidth / 3 {
                    previousPage()
                } else if x > viewWidth * 2 / 3 {
                    nextPage()
                } else {
                    showChrome.toggle()
                }
            }
    }

    /// Swipe gesture for page navigation
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5 else { return }
                if dx < 0 { nextPage(animated: true) } else { previousPage(animated: true) }
            }
    }
    #endif

    // MARK: - Scrolling Content

    @ViewBuilder
    private var scrollingContent: some View {
        ZoomableComicStripView(
            pages: archive.pages,
            containerSize: CGSize(width: viewWidth, height: viewHeight),
            trimWhitespace: trimWhitespace,
            onTap: { showChrome.toggle() },
            currentPage: $currentPage,
            zoomScale: $zoomScale
        )
    }

    /// Two-page spread view, respecting reading direction.
    @ViewBuilder
    private var twoPageSpread: some View {
        let isCover = coverOnRight && currentPage == 0
        let second = !isCover && currentPage + 1 < archive.pageCount ? currentPage + 1 : nil
        let leading: Int? = isCover ? nil : currentPage
        let trailing: Int? = isCover ? currentPage : second
        let left = readingDirection == .leftToRight ? leading : trailing
        let right = readingDirection == .leftToRight ? trailing : leading
        let m = readingPrefs.effective(for: fileHash).marginsTwoUp

        HStack(spacing: m.leftRight) {
            spreadPage(left)
            spreadPage(right)
        }
        .padding(.horizontal, m.leftRight)
    }

    @ViewBuilder
    private func spreadPage(_ index: Int?) -> some View {
        Group {
            if let index {
                ComicPageView(imageURL: archive.pages[index], trimWhitespace: trimWhitespace)
                    .id(index)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookmarkedComicPages: Set<Int> {
        Set(bookmarkStore.bookmarks(for: fileHash).compactMap { entry -> Int? in
            if case .comicPage(let page) = entry.position { return page }
            return nil
        })
    }

    private var isCurrentPositionBookmarked: Bool {
        return bookmarkStore.isPositionBookmarked(fileHash: fileHash, position: .comicPage(currentPage))
    }

    private var pageLabel: String {
        ReaderHelpers.pageLabel(current: currentPage, total: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
    }

    private func previousPage(animated: Bool = false) {
        zoomScale = 1.0
        let newPage = PageNavigation.previous(
            current: currentPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
        guard newPage != currentPage else { return }
        navigatingForward = false
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { currentPage = newPage }
        } else {
            currentPage = newPage
        }
    }

    private func nextPage(animated: Bool = false) {
        zoomScale = 1.0
        let newPage = PageNavigation.next(
            current: currentPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight)
        guard newPage != currentPage else { return }
        navigatingForward = true
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { currentPage = newPage }
        } else {
            currentPage = newPage
        }
    }

    private func restorePosition() {
        if let page = ReaderHelpers.restorePagePosition(store: bookmarkStore, fileHash: fileHash, pageCount: archive.pageCount, extract: {
            if case .comicPage(let p) = $0 { return p }; return nil
        }) {
            currentPage = page
        }
    }

    private func toggleBookmark() {
        ReaderHelpers.toggleBookmark(
            store: bookmarkStore, fileURL: fileURL, fileHash: fileHash,
            rawData: rawData, position: .comicPage(currentPage)
        )
    }

    private func autoSavePosition() {
        guard let url = fileURL else { return }
        guard archive.pageCount > 0 else { return }
        let position: ReadingPosition = .comicPage(currentPage)
        bookmarkStore.savePosition(position, for: url, data: rawData, fileHash: fileHash, session: readingSession)
    }

    // MARK: - Search (OCR)

    private func performComicSearch(_ query: String) {
        // Cancel any in-flight OCR scan from a previous query.
        ocrSearchTask?.cancel()
        ocrSearchTask = nil

        search.isSearching = true
        searchMatchPages = []
        search.currentIndex = 0
        ocrPagesScanned = 0

        search.error = nil
        ocrSearchTask = Task {
            do {
                for (index, page) in archive.pages.enumerated() {
                    try Task.checkCancellation()
                    let contains = try await OCRService.shared.pageContains(imageURL: page, query: query)
                    try Task.checkCancellation()
                    ocrPagesScanned = index + 1
                    if contains { searchMatchPages.append(index) }
                }
                search.isSearching = false
                if let first = searchMatchPages.first { currentPage = first }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                search.isSearching = false
                search.error = "Search could not finish. Results may be incomplete. \(error.localizedDescription)"
            }
        }
    }

    private func clearComicSearch() {
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        searchMatchPages = []
        search.currentIndex = 0
        search.isSearching = false
        ocrPagesScanned = 0
    }

    private func navigateComicSearchResult(forward: Bool) {
        guard !searchMatchPages.isEmpty else { return }
        if forward {
            search.currentIndex = (search.currentIndex + 1) % searchMatchPages.count
        } else {
            search.currentIndex = (search.currentIndex - 1 + searchMatchPages.count) % searchMatchPages.count
        }
        currentPage = searchMatchPages[search.currentIndex]
    }

    private func dismissComicSearch() {
        searchDebouncer.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        search.reset()
        searchMatchPages = []
        ocrPagesScanned = 0
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
        let anchor = pairingAnchorPage ?? currentPage
        let shifted = effectiveTwoUp ? !coverOnRight : coverOnRight
        pairingAnchorPage = anchor
        readingPrefs.setViewMode(.paginated, twoUp: true, coverOnRight: shifted, for: fileHash)
        currentPage = PageNavigation.normalizedStart(
            current: anchor, pageCount: archive.pageCount, twoUp: true, coverOnRight: shifted)
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

    private var currentModeIcon: String {
        ReaderHelpers.viewModeIcon(isPaginated: isPaginated, twoUpOverride: twoUpOverride)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var comicToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: { previousPage() }) {
                Label("Previous Page", systemImage: "chevron.left")
            }
            .disabled(!PageNavigation.canGoPrevious(
                current: currentPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))

            Button(action: { nextPage() }) {
                Label("Next Page", systemImage: "chevron.right")
            }
            .disabled(!PageNavigation.canGoNext(
                current: currentPage, pageCount: archive.pageCount, twoUp: effectiveTwoUp, coverOnRight: coverOnRight))
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
                      systemImage: trimWhitespace ? "arrow.up.left.and.arrow.down.right" : "crop")
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
            Button { search.isShowing.toggle(); if !search.isShowing { dismissComicSearch() } } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { showSettings = true } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
        }
    }
}

/// Displays a single comic page image, optionally trimming whitespace borders.
private struct ComicPageView: View {
    let imageURL: URL
    var trimWhitespace: Bool = false

    #if os(macOS)
    @State private var loadedImage: NSImage?
    #else
    @State private var loadedImage: UIImage?
    #endif

    var body: some View {
        Group {
            if let image = loadedImage {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #else
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #endif
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ImageTaskID(url: imageURL, trim: trimWhitespace)) {
            loadedImage = await loadImageAsync()
        }
    }

    private struct ImageTaskID: Equatable, Hashable {
        let url: URL
        let trim: Bool
    }

    #if os(macOS)
    private func loadImageAsync() async -> NSImage? {
        let url = imageURL
        let trim = trimWhitespace
        return await Task.detached {
            guard let image = loadComicPageCGImage(
                at: url, trim: trim, maxPixelSize: 4_096) else { return nil }
            return NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }.value
    }
    #else
    private func loadImageAsync() async -> UIImage? {
        let url = imageURL
        let trim = trimWhitespace
        return await Task.detached {
            loadComicPageCGImage(at: url, trim: trim, maxPixelSize: 4_096)
                .map(UIImage.init(cgImage:))
        }.value
    }
    #endif
}

// MARK: - Comic Thumbnail Sidebar

private struct ComicThumbnailSidebar: View {
    let archive: ComicArchive
    @Binding var currentPage: Int
    var bookmarkedPages: Set<Int> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<archive.pageCount, id: \.self) { index in
                        ComicPageThumbnail(imageURL: archive.pages[index], pageIndex: index, isSelected: index == currentPage, isBookmarked: bookmarkedPages.contains(index))
                            .id(index)
                            .onTapGesture {
                                currentPage = index
                            }
                    }
                }
                .padding(8)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                guard currentPage > 0 else { return .ignored }
                currentPage -= 1
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard currentPage < archive.pageCount - 1 else { return .ignored }
                currentPage += 1
                return .handled
            }
            .navigationTitle("Pages")
            .onChange(of: currentPage) { _, newValue in
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .task {
                proxy.scrollTo(currentPage, anchor: .center)
            }
        }
    }
}

private struct ComicPageThumbnail: View {
    let imageURL: URL
    let pageIndex: Int
    let isSelected: Bool
    var isBookmarked: Bool = false

    #if os(macOS)
    @State private var loadedImage: NSImage?
    #else
    @State private var loadedImage: UIImage?
    #endif

    var body: some View {
        VStack(spacing: 2) {
            thumbnailImage
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 180)
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
        .task(id: imageURL) {
            loadedImage = await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let image = loadedImage {
            #if os(macOS)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
            #else
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
            #endif
        } else {
            Color.clear
        }
    }

    #if os(macOS)
    private func loadThumbnail() async -> NSImage? {
        let url = imageURL
        return await Task.detached {
            guard let cg = loadComicThumbnail(at: url, maxPixelSize: 360) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
    #else
    private func loadThumbnail() async -> UIImage? {
        let url = imageURL
        return await Task.detached {
            guard let cg = loadComicThumbnail(at: url, maxPixelSize: 360) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
    #endif
}
