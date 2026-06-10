import SwiftUI
import PDFKit

/// Displays a PDF document with page navigation, thumbnail sidebar, and bookmark toggle.
struct PDFReaderView: View {
    let data: Data
    let fileURL: URL?
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    private let fileHash: String?

    init(data: Data, fileURL: URL?, showChrome: Binding<Bool>, onClose: (() -> Void)? = nil) {
        self.data = data
        self.fileURL = fileURL
        self._showChrome = showChrome
        self.onClose = onClose
        self.fileHash = FileHasher.hash(data: data)
    }

    @State private var currentPageIndex: Int = 0
    @State private var pdfDocument: PDFDocument?
    @State private var didAttemptLoad: Bool = false
    @State private var pageCount: Int = 0
    @State private var showGoToPage: Bool = false
    @State private var goToPageText: String = ""
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    @State private var showThumbnails: Bool = false
    @State private var viewMode: ViewMode = .paginated
    @State private var trimWhitespace: Bool = false
    @State private var originalPDFBounds: [Int: CGRect] = [:]
    @State private var trimmedPages: Set<Int> = []
    @State private var trimTask: Task<Void, Never>?
    @State private var twoUpOverride: Bool? = nil
    @State private var zoomScale: Double? = nil
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0

    // Slider scrubbing state — defers page navigation until drag ends
    @State private var sliderDragging: Bool = false
    @State private var sliderPageIndex: Int = 0

    @State private var fastScroll = FastScrollController()

    // Search state
    @State private var search = ReaderSearchState()
    @State private var searchSelections: [PDFSelection] = []
    @State private var ocrMatchPages: [Int] = []
    @State private var usingOCR = false
    @State private var searchDebouncer = SearchDebouncer()
    @State private var ocrSearchTask: Task<Void, Never>?

    @FocusState private var isFocused: Bool

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var isPaginated: Bool {
        viewMode == .paginated
    }

    /// Whether to use cropBox-based trimming on the PDFDocument.
    /// On iOS paginated mode, PaginatedPDFContainerView handles trimming
    /// via image-level cropping, so cropBox modification must be skipped
    /// to avoid double-cropping (cropBox + image crop = content clipped).
    private var usesCropBoxTrimming: Bool {
        #if os(iOS)
        return !isPaginated
        #else
        return true
        #endif
    }

    private var effectiveTwoUp: Bool {
        guard isPaginated else { return false }
        return twoUpOverride ?? ReaderHelpers.defaultTwoUp(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    var body: some View {
        pdfLayout
            #if os(macOS)
            .toolbar { pdfToolbar }
            #endif
            .fullScreenToolbarAutoHide(showChrome: $showChrome)
            .task {
                readingPrefs.touchLastUsed(for: fileHash)
                let eff = readingPrefs.effective(for: fileHash)
                viewMode = eff.viewMode
                twoUpOverride = eff.twoUp
                trimWhitespace = eff.trimWhitespace
                loadDocument()
                // Note: loadDocument() calls applyTrimCropBoxes() only when
                // usesCropBoxTrimming is true (macOS always, iOS scrolling).
                // iOS paginated mode trims via image cropping in
                // PaginatedPDFContainerView instead.
            }
            .onDisappear {
                autoSavePosition()
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
                onZoomOut: { zoomScale = max(0.25, (zoomScale ?? 1.0) / 1.25) }
            ))
            .onReaderCommand(.showGoToPage) {
                showGoToPage = true
            }
            .onChange(of: search.query) { _, newQuery in
                searchDebouncer.handle(newQuery, perform: performPdfSearch, clear: clearPdfSearch)
            }
            .onChange(of: currentPageIndex) { _, newPage in
                if trimWhitespace && usesCropBoxTrimming && isPaginated { trimPagesAround(newPage) }
                autoSavePosition()
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
                    BookmarkPickerView(fileHash: fileHash ?? "") { position in
                        if case .pdfPage(let page) = position, page < pageCount {
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
        guard !usingOCR, search.currentIndex < searchSelections.count else { return nil }
        return searchSelections[search.currentIndex]
    }

    @ViewBuilder
    private func pdfContentView(doc: PDFDocument) -> some View {
        #if os(iOS)
        if isPaginated {
            PaginatedPDFContainerView(
                pdfDocument: doc,
                currentPage: $currentPageIndex,
                twoUp: effectiveTwoUp,
                trimWhitespace: trimWhitespace,
                documentKey: fileHash ?? "doc",
                onToggleChrome: { showChrome.toggle() }
            )
        } else {
            PDFViewRepresentable(
                pdfDocument: doc,
                currentPageIndex: $currentPageIndex,
                paginated: false,
                scaleFactor: zoomScale,
                highlightSelection: currentHighlightSelection,
                onToggleChrome: { showChrome.toggle() }
            )
        }
        #else
        PDFViewRepresentable(
            pdfDocument: doc,
            currentPageIndex: $currentPageIndex,
            paginated: isPaginated,
            twoUp: effectiveTwoUp,
            scaleFactor: zoomScale,
            highlightSelection: currentHighlightSelection,
            onToggleChrome: { showChrome.toggle() }
        )
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
            Rectangle().fill(.bar).ignoresSafeArea(edges: .top)
        }
    }
    #endif

    /// The page index to display in the bottom bar — uses the scrub target while
    /// the slider is being dragged so the label updates instantly without triggering
    /// expensive page navigation on every intermediate value.
    private var displayedPageIndex: Int {
        sliderDragging ? sliderPageIndex : currentPageIndex
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
                Text(ReaderHelpers.pageLabel(current: displayedPageIndex, total: pageCount, twoUp: effectiveTwoUp))
                    .font(.caption).monospacedDigit()
                Spacer()
                let pct = pageCount > 1 ? Int(Double(displayedPageIndex) / Double(pageCount - 1) * 100) : 0
                Text("\(pct)%").font(.caption).monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
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
            .disabled(currentPageIndex <= 0)

            Button(action: nextPage) {
                Label("Next Page", systemImage: "chevron.right")
            }
            .disabled(currentPageIndex >= pageCount - 1)
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
        Set(bookmarkStore.bookmarks(for: fileHash ?? "").compactMap { entry -> Int? in
            if case .pdfPage(let page) = entry.position { return page }
            return nil
        })
    }

    private var isCurrentPositionBookmarked: Bool {
        guard let hash = fileHash else { return false }
        return bookmarkStore.isPositionBookmarked(fileHash: hash, position: .pdfPage(currentPageIndex))
    }

    private var pageStep: Int {
        effectiveTwoUp ? 2 : 1
    }

    private var pageLabel: String {
        ReaderHelpers.pageLabel(current: currentPageIndex, total: pageCount, twoUp: effectiveTwoUp)
    }

    private func previousPage() {
        let newIndex = max(currentPageIndex - pageStep, 0)
        if newIndex != currentPageIndex { currentPageIndex = newIndex }
    }

    private func nextPage() {
        let newIndex = min(currentPageIndex + pageStep, pageCount - 1)
        if newIndex != currentPageIndex { currentPageIndex = newIndex }
    }

    private func loadDocument() {
        // Prefer URL-based loading — PDFKit memory-maps the file, instant even for 100MB+ PDFs.
        // Fall back to data-based loading when no URL is available.
        let doc = fileURL.flatMap { PDFDocument(url: $0) } ?? PDFDocument(data: data)
        didAttemptLoad = true
        guard let doc else { return }

        pdfDocument = doc
        pageCount = doc.pageCount

        // Restore position: auto-saved first, then manual bookmarks
        if let page = ReaderHelpers.restorePagePosition(store: bookmarkStore, fileHash: fileHash, pageCount: doc.pageCount, extract: {
            if case .pdfPage(let p) = $0 { return p }; return nil
        }) {
            currentPageIndex = page
        }

        if trimWhitespace && usesCropBoxTrimming {
            applyTrimCropBoxes()
        }
    }

    // MARK: - Search

    private var pdfSearchResultCount: Int {
        usingOCR ? ocrMatchPages.count : searchSelections.count
    }

    private func performPdfSearch(_ query: String) {
        guard let doc = pdfDocument else {
            clearPdfSearch()
            return
        }
        // Cancel any in-flight OCR scan from a previous query.
        ocrSearchTask?.cancel()
        ocrSearchTask = nil

        search.isSearching = true
        usingOCR = false
        ocrMatchPages = []

        // First try PDFKit text search
        let selections = doc.findString(query, withOptions: [.caseInsensitive])
        searchSelections = selections
        search.currentIndex = 0

        if !selections.isEmpty {
            search.isSearching = false
            if let first = selections.first {
                navigateToSelection(first)
            }
        } else {
            // No text layer results — fall back to OCR
            usingOCR = true
            performOCRPdfSearch(query, doc: doc)
        }
    }

    private func clearPdfSearch() {
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        searchSelections = []
        ocrMatchPages = []
        usingOCR = false
        search.currentIndex = 0
        search.isSearching = false
    }

    private func performOCRPdfSearch(_ query: String, doc: PDFDocument) {
        ocrSearchTask = Task {
            var matches: [Int] = []
            for i in 0..<doc.pageCount {
                if Task.isCancelled { return }
                guard let page = doc.page(at: i) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let size = CGSize(width: min(bounds.width * 2, 2000), height: min(bounds.height * 2, 2000))
                let thumbnail = page.thumbnail(of: size, for: .mediaBox)

                // Save thumbnail to temp file for OCR. The file hash keeps the
                // path (and OCRService's URL-keyed cache) distinct per document.
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("raedad-pdf-ocr-\(fileHash ?? "doc")-\(i).png")
                #if canImport(UIKit)
                if let data = thumbnail.pngData() {
                    try? data.write(to: tmpURL)
                }
                #else
                if let tiff = thumbnail.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: tmpURL)
                }
                #endif

                let contains = await OCRService.shared.pageContains(imageURL: tmpURL, query: query)
                if Task.isCancelled { return }
                if contains {
                    matches.append(i)
                }
                await MainActor.run {
                    if !Task.isCancelled { ocrMatchPages = matches }
                }
            }
            await MainActor.run {
                if Task.isCancelled { return }
                search.isSearching = false
                if let first = matches.first {
                    currentPageIndex = first
                }
            }
        }
    }

    private func navigatePdfSearchResult(forward: Bool) {
        let count = pdfSearchResultCount
        guard count > 0 else { return }
        if forward {
            search.currentIndex = (search.currentIndex + 1) % count
        } else {
            search.currentIndex = (search.currentIndex - 1 + count) % count
        }
        if usingOCR {
            currentPageIndex = ocrMatchPages[search.currentIndex]
        } else {
            navigateToSelection(searchSelections[search.currentIndex])
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
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        search.reset()
        searchSelections = []
        ocrMatchPages = []
        usingOCR = false
    }

    private func toggleBookmark() {
        ReaderHelpers.toggleBookmark(
            store: bookmarkStore, fileURL: fileURL, fileHash: fileHash,
            rawData: data, position: .pdfPage(currentPageIndex)
        )
    }

    /// Skip page 0 so closing on the cover page doesn't pin the auto-restore
    /// to "page 1" forever. The user is treated as "hasn't read yet" until
    /// they advance past the first page. Comic reader uses the same rule.
    private func autoSavePosition() {
        guard let url = fileURL else { return }
        guard currentPageIndex > 0 else { return }
        let position: ReadingPosition = .pdfPage(currentPageIndex)
        bookmarkStore.savePosition(position, for: url, data: data)
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
        if usesCropBoxTrimming {
            if trimWhitespace {
                applyTrimCropBoxes()
            } else {
                restoreOriginalCropBoxes()
            }
        }
        readingPrefs.updatePreference(for: fileHash, apply: { $0.trimWhitespace = trimWhitespace }, applyGlobal: { readingPrefs.trimWhitespace = trimWhitespace })
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
        guard let doc = pdfDocument else { return }
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

        // Build page order: center first, then expanding outward.
        // Pages are marked in `trimmedPages` only after their crop box is
        // applied — a pass cancelled mid-way must not leave pages permanently
        // skipped. Re-running over an in-flight page is cheap: ContentTrimmer
        // caches the detected rect by key.
        var pageOrder: [Int] = []
        var scheduled = Set<Int>()
        for dist in 0..<count {
            for candidate in [center + dist, center - dist] {
                if candidate >= 0, candidate < count, !trimmedPages.contains(candidate),
                   !scheduled.contains(candidate) {
                    pageOrder.append(candidate)
                    scheduled.insert(candidate)
                }
            }
        }
        guard !pageOrder.isEmpty else { return }

        let url = fileURL
        let pdfData = data

        trimTask?.cancel()
        trimTask = Task {
            let bgDoc: PDFDocument? = await Task.detached {
                if let url { return PDFDocument(url: url) }
                return PDFDocument(data: pdfData)
            }.value
            guard let bgDoc, !Task.isCancelled else { return }

            if allPages {
                // Scrolling mode: compute all crop boxes first, then batch-apply
                var cropBoxes: [Int: CGRect] = [:]
                for i in pageOrder {
                    guard !Task.isCancelled else { return }
                    if let box = await computeCropBox(bgDoc: bgDoc, pageIndex: i) {
                        cropBoxes[i] = box
                    }
                }
                guard !Task.isCancelled else { return }
                for (i, box) in cropBoxes {
                    doc.page(at: i)?.setBounds(box, for: .cropBox)
                }
                trimmedPages.formUnion(pageOrder)
            } else {
                // Paginated mode: apply incrementally for fast first-page display
                for i in pageOrder {
                    guard !Task.isCancelled else { return }
                    if let cropBox = await computeCropBox(bgDoc: bgDoc, pageIndex: i) {
                        doc.page(at: i)?.setBounds(cropBox, for: .cropBox)
                    }
                    trimmedPages.insert(i)
                }
            }
        }
    }

    /// Computes the trimmed crop box for a single page on a background thread.
    private func computeCropBox(bgDoc: PDFDocument, pageIndex i: Int) async -> CGRect? {
        let trimKey = "pdf-crop-\(fileHash ?? "doc")-\(i)"
        return await Task.detached {
            guard let page = bgDoc.page(at: i) else { return nil }
            let mediaBox = page.bounds(for: .mediaBox)
            let thumbScale: CGFloat = min(1000 / mediaBox.width, 1000 / mediaBox.height, 2.0)
            let size = CGSize(width: mediaBox.width * thumbScale, height: mediaBox.height * thumbScale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)

            #if canImport(UIKit)
            guard let cgImage = thumbnail.cgImage else { return nil }
            #else
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            #endif

            let contentRect = ContentTrimmer.shared.contentRect(for: cgImage, key: trimKey)
            guard contentRect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return nil }

            return CGRect(
                x: mediaBox.origin.x + contentRect.minX * mediaBox.width,
                y: mediaBox.origin.y + (1.0 - contentRect.maxY) * mediaBox.height,
                width: contentRect.width * mediaBox.width,
                height: contentRect.height * mediaBox.height
            ) as CGRect?
        }.value
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
    @Binding var currentPageIndex: Int
    var bookmarkedPages: Set<Int> = []

    private var pageCount: Int { pdfDocument?.pageCount ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let doc = pdfDocument {
                        ForEach(0..<doc.pageCount, id: \.self) { index in
                            PDFPageThumbnail(document: doc, pageIndex: index, isSelected: index == currentPageIndex, isBookmarked: bookmarkedPages.contains(index))
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
            // Generate thumbnail off the main thread
            let doc = document
            let idx = pageIndex
            let result: CGImage? = await Task.detached(priority: .utility) {
                guard let page = doc.page(at: idx) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let aspect = bounds.width / bounds.height
                let size = CGSize(width: 160, height: 160 / aspect)
                let platformImage = page.thumbnail(of: size, for: .mediaBox)
                #if os(macOS)
                return platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                return platformImage.cgImage
                #endif
            }.value
            if !Task.isCancelled {
                thumbnail = result
            }
        }
    }
}
