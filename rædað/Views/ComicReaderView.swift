import SwiftUI

/// Displays CBZ comic pages with arrow navigation, thumbnail sidebar, and bookmark toggle.
/// Supports paginated (single/two-page) and scrolling (vertical strip) view modes.
struct ComicReaderView: View {
    let archive: ComicArchive
    let fileURL: URL?
    let rawData: Data
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    private let fileHash: String?

    init(archive: ComicArchive, fileURL: URL?, rawData: Data, showChrome: Binding<Bool>, onClose: (() -> Void)? = nil) {
        self.archive = archive
        self.fileURL = fileURL
        self.rawData = rawData
        self._showChrome = showChrome
        self.onClose = onClose
        self.fileHash = FileHasher.hash(data: rawData)
    }

    @State private var currentPage: Int = 0
    @State private var readingDirection: ComicArchive.ReadingDirection = .leftToRight
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    @State private var showThumbnails: Bool = false
    @State private var twoUpOverride: Bool? = nil
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @State private var viewMode: ViewMode = .paginated
    @State private var trimWhitespace: Bool = false
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
        return twoUpOverride ?? ReaderHelpers.defaultTwoUp(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    var body: some View {
        comicLayoutWithNotifications
            .task {
                readingPrefs.touchLastUsed(for: fileHash)
                let eff = readingPrefs.effective(for: fileHash)
                viewMode = eff.viewMode
                twoUpOverride = eff.twoUp
                trimWhitespace = eff.trimWhitespace
                restorePosition()
            }
            .onDisappear {
                autoSavePosition()
            }
            .onChange(of: currentPage) { _, _ in
                autoSavePosition()
            }
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash ?? "") { position in
                        if case .comicPage(let page) = position, page < archive.pageCount {
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
                Button("Done", action: onClose)
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
            Rectangle().fill(.bar).ignoresSafeArea(edges: .top)
        }
    }
    #endif

    private var displayedComicPage: Int {
        sliderDragging ? sliderPageIndex : currentPage
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
                Text(ReaderHelpers.pageLabel(current: displayedComicPage, total: archive.pageCount, twoUp: effectiveTwoUp))
                    .font(.caption).monospacedDigit()
                Spacer()
                let pct = archive.pageCount > 1 ? Int(Double(displayedComicPage) / Double(archive.pageCount - 1) * 100) : 0
                Text("\(pct)%").font(.caption).monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: - Paginated Content

    @ViewBuilder
    private var paginatedContent: some View {
        #if os(iOS)
        PaginatedComicContainerView(
            pages: archive.pages,
            currentPage: $currentPage,
            twoUp: effectiveTwoUp,
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
        let hasSecondPage = currentPage + 1 < archive.pageCount
        let m = readingPrefs.effective(for: fileHash).marginsTwoUp

        HStack(spacing: m.leftRight) {
            if readingDirection == .leftToRight {
                ComicPageView(imageURL: archive.pages[currentPage], trimWhitespace: trimWhitespace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("left-\(currentPage)")
                if hasSecondPage {
                    ComicPageView(imageURL: archive.pages[currentPage + 1], trimWhitespace: trimWhitespace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("right-\(currentPage + 1)")
                }
            } else {
                if hasSecondPage {
                    ComicPageView(imageURL: archive.pages[currentPage + 1], trimWhitespace: trimWhitespace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("left-\(currentPage + 1)")
                }
                ComicPageView(imageURL: archive.pages[currentPage], trimWhitespace: trimWhitespace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("right-\(currentPage)")
            }
        }
        .padding(.horizontal, m.leftRight)
    }

    private var bookmarkedComicPages: Set<Int> {
        Set(bookmarkStore.bookmarks(for: fileHash ?? "").compactMap { entry -> Int? in
            if case .comicPage(let page) = entry.position { return page }
            return nil
        })
    }

    private var isCurrentPositionBookmarked: Bool {
        guard let hash = fileHash else { return false }
        return bookmarkStore.isPositionBookmarked(fileHash: hash, position: .comicPage(currentPage))
    }

    /// Number of pages to step when navigating in two-up mode.
    private var pageStep: Int {
        effectiveTwoUp ? 2 : 1
    }

    private var pageLabel: String {
        ReaderHelpers.pageLabel(current: currentPage, total: archive.pageCount, twoUp: effectiveTwoUp)
    }

    private func previousPage(animated: Bool = false) {
        zoomScale = 1.0
        let step = pageStep
        let newPage: Int
        if currentPage - step >= 0 {
            newPage = currentPage - step
        } else if currentPage != 0 {
            newPage = 0
        } else {
            return
        }
        navigatingForward = false
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { currentPage = newPage }
        } else {
            currentPage = newPage
        }
    }

    private func nextPage(animated: Bool = false) {
        zoomScale = 1.0
        let step = pageStep
        guard currentPage + step < archive.pageCount else { return }
        let newPage = currentPage + step
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
        guard currentPage > 0 else { return }
        let position: ReadingPosition = .comicPage(currentPage)
        bookmarkStore.savePosition(position, for: url, data: rawData)
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

        ocrSearchTask = Task {
            var matches: [Int] = []
            for i in 0..<archive.pageCount {
                if Task.isCancelled { return }
                let contains = await OCRService.shared.pageContains(imageURL: archive.pages[i], query: query)
                if Task.isCancelled { return }
                if contains {
                    matches.append(i)
                }
                await MainActor.run {
                    if Task.isCancelled { return }
                    ocrPagesScanned = i + 1
                    searchMatchPages = matches
                }
            }
            await MainActor.run {
                if Task.isCancelled { return }
                search.isSearching = false
                if let first = matches.first {
                    currentPage = first
                }
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
        viewMode = .paginated
        twoUpOverride = nil
        readingPrefs.setViewMode(.paginated, twoUp: nil, for: fileHash)
    }

    private func selectSinglePage() {
        viewMode = .paginated
        twoUpOverride = false
        readingPrefs.setViewMode(.paginated, twoUp: false, for: fileHash)
    }

    private func selectTwoPage() {
        viewMode = .paginated
        twoUpOverride = true
        readingPrefs.setViewMode(.paginated, twoUp: true, for: fileHash)
    }

    private func selectScrolling() {
        viewMode = .scrolling
        readingPrefs.setViewMode(.scrolling, twoUp: nil, for: fileHash)
    }

    private func toggleTrim() {
        trimWhitespace.toggle()
        readingPrefs.updatePreference(for: fileHash, apply: { $0.trimWhitespace = trimWhitespace }, applyGlobal: { readingPrefs.trimWhitespace = trimWhitespace })
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
            .disabled(currentPage <= 0)

            Button(action: { nextPage() }) {
                Label("Next Page", systemImage: "chevron.right")
            }
            .disabled(currentPage + pageStep >= archive.pageCount)
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
        return await Task.detached { loadComicImage(at: url, trim: trim) }.value
    }
    #else
    private func loadImageAsync() async -> UIImage? {
        let url = imageURL
        let trim = trimWhitespace
        return await Task.detached { loadComicImage(at: url, trim: trim) }.value
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

