import SwiftUI
import AVFoundation

/// Displays plain text or Markdown.
/// Scrolling mode uses a chunked LazyVStack for raw text, or WebView for rendered markdown.
/// Paginated mode uses WebViewRepresentable for both raw and rendered content.
struct TextReaderView: View {
    let content: TextContent
    let fileURL: URL?
    let rawData: Data
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    private let fileHash: String?

    init(content: TextContent, fileURL: URL?, rawData: Data, showChrome: Binding<Bool>, onClose: (() -> Void)? = nil) {
        self.content = content
        self.fileURL = fileURL
        self.rawData = rawData
        self._showChrome = showChrome
        self.onClose = onClose
        self.fileHash = FileHasher.hash(data: rawData)
    }

    @State private var scrollFraction: Double = 0.0
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 1
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    @State private var viewMode: ViewMode = .scrolling
    @State private var twoUpOverride: Bool? = nil
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @State private var webViewProxy = WebViewProxy()
    @State private var htmlFileURL: URL?
    @State private var htmlBaseURL: URL?
    @State private var scrollTarget: Int? = nil
    @State private var cachedTextChunks: [String] = []
    @State private var renderMarkdown: Bool = false
    @State private var showTOC: Bool = false

    // Auto-save debounce
    @State private var autoSaveTimer: Timer?

    // Key repeat quick vanish state
    @State private var keyRepeatCount: Int = 0
    @State private var fastScrollTimer: Timer?

    // Read-aloud state (iOS only)
    #if os(iOS) || os(visionOS)
    private let readAloud = ReadAloudController.shared
    #endif

    // Search state
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchMatchOffsets: [Range<String.Index>] = []
    @State private var currentSearchIndex = 0
    @State private var isSearching = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var effective: EffectivePreferences {
        readingPrefs.effective(for: fileHash)
    }

    private var activeMargins: MarginSettings {
        effectiveTwoUp ? effective.marginsTwoUp : effective.marginsOneUp
    }

    private var isPaginated: Bool {
        viewMode == .paginated
    }

    /// Whether two-page spread should be active. Only in paginated mode.
    private var effectiveTwoUp: Bool {
        guard isPaginated else { return false }
        return twoUpOverride ?? ReaderHelpers.defaultTwoUp(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    private var isMarkdown: Bool {
        if case .markdown = content { return true }
        return false
    }

    /// Whether to use a WebView for the current display mode.
    /// WebView is used for paginated mode (always) and for rendered markdown in scrolling mode.
    private var useWebView: Bool {
        isPaginated || (isMarkdown && renderMarkdown)
    }

    #if os(iOS)
    private var safeAreaBackground: Color {
        effective.theme.swiftUIBackground ?? Color(.systemBackground)
    }
    #endif

    /// The raw text string from either plain or markdown content.
    private var rawText: String {
        switch content {
        case .plain(let text): text
        case .markdown(let text): text
        }
    }

    /// Lines chunked for lazy rendering in scrolling mode.
    /// Groups of 100 lines to balance view count vs. rendering cost.
    /// Cached in `cachedTextChunks` @State; recomputed when reflowText changes.
    private func computeTextChunks() -> [String] {
        let source = (effective.reflowText && !isMarkdown) ? TextReflow.reflow(rawText) : rawText
        let lines = source.components(separatedBy: "\n")
        let chunkSize = 100
        var chunks: [String] = []
        chunks.reserveCapacity((lines.count + chunkSize - 1) / chunkSize)
        var i = 0
        while i < lines.count {
            let end = min(i + chunkSize, lines.count)
            chunks.append(lines[i..<end].joined(separator: "\n"))
            i = end
        }
        return chunks
    }

    enum TextContent {
        case plain(String)
        case markdown(String)
    }

    struct MarkdownHeading: Identifiable {
        let id: String      // anchor ID e.g. "toc-0"
        let title: String
        let level: Int      // 1-6
        let lineIndex: Int  // line number in source
    }

    /// Parsed headings from the markdown source for TOC generation.
    private var markdownTOCEntries: [MarkdownHeading] {
        guard isMarkdown else { return [] }
        let lines = rawText.components(separatedBy: "\n")
        var entries: [MarkdownHeading] = []
        var inCodeBlock = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }
            if let (level, text) = parseHeader(trimmed) {
                entries.append(MarkdownHeading(
                    id: "toc-\(entries.count)",
                    title: text,
                    level: level,
                    lineIndex: i
                ))
            }
        }
        return entries
    }

    var body: some View {
        textLayoutWithToolbar
            .sheet(isPresented: $showBookmarks) {
                NavigationStack {
                    BookmarkPickerView(fileHash: fileHash ?? "") { position in
                        if case .textOffset(let offset) = position {
                            let fraction = Double(offset) / 1000.0
                            scrollFraction = fraction
                            if isPaginated {
                                let page = max(0, Int(round(fraction * Double(totalPages - 1))))
                                webViewProxy.goToPage?(page)
                            } else {
                                let chunks = cachedTextChunks
                                let targetIndex = min(Int(round(fraction * Double(chunks.count - 1))), chunks.count - 1)
                                scrollTarget = targetIndex
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ReaderSettingsSheet(fileHash: fileHash, showReflowOption: !isMarkdown)
            }
            .onChange(of: renderMarkdown) { _, _ in
                prepareHTMLFile()
            }
            .onChange(of: effective.reflowText) { _, _ in
                cachedTextChunks = computeTextChunks()
                prepareHTMLFile()
            }
            .task {
                readingPrefs.touchLastUsed(for: fileHash)
                let eff = readingPrefs.effective(for: fileHash)
                viewMode = eff.viewMode
                twoUpOverride = eff.twoUp
                // Restore saved scroll fraction before WebView renders,
                // so the initial WebViewContent gets the correct position.
                if let hash = fileHash,
                   let saved = bookmarkStore.savedPosition(for: hash),
                   case .textOffset(let off) = saved.position, off > 0 {
                    scrollFraction = Double(off) / 1000.0
                }
                renderMarkdown = isMarkdown
                cachedTextChunks = computeTextChunks()
                prepareHTMLFile()
            }
            .onDisappear {
                autoSaveTimer?.invalidate()
                autoSavePosition()
                #if os(iOS) || os(visionOS)
                if readAloud.isActive { readAloud.dismiss() }
                #endif
            }
            .onChange(of: scrollFraction) { _, _ in
                autoSaveTimer?.invalidate()
                autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    Task { @MainActor in autoSavePosition() }
                }
            }
    }

    @ViewBuilder
    private var textLayoutWithToolbar: some View {
        textLayoutWithNotifications
            #if os(macOS)
            .toolbar { textToolbar }
            #endif
            .fullScreenToolbarAutoHide(showChrome: $showChrome)
    }

    @ViewBuilder
    private var textLayoutWithNotifications: some View {
        textLayout
            .onReceive(NotificationCenter.default.publisher(for: .showReadingSettings)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarkPosition)) { _ in
                toggleBookmark()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTableOfContents)) { _ in
                showTOC.toggle()
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
            .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
                showSearch.toggle()
                if !showSearch { dismissTextSearch() }
            }
            #if os(iOS) || os(visionOS)
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadAloud)) { _ in
                toggleReadAloud()
            }
            #endif
            .onChange(of: searchQuery) { _, newQuery in
                performTextSearch(newQuery)
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var textLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showTOC && sizeClass != .compact {
                    textSidebar
                        .frame(width: 280)
                    Divider()
                }
                GeometryReader { geometry in
                    Group {
                        if useWebView, let fileURL = htmlFileURL, let baseURL = htmlBaseURL {
                            WebViewRepresentable(
                                content: WebViewContent(
                                    fileURL: fileURL,
                                    baseURL: baseURL,
                                    scrollFraction: scrollFraction > 0 ? scrollFraction : nil,
                                    fragment: nil,
                                    cssOverride: effective.cssString,
                                    paginated: isPaginated,
                                    twoUp: isPaginated ? twoUpOverride : nil,
                                    marginTopBottom: activeMargins.topBottom,
                                    marginLeftRight: activeMargins.leftRight
                                ),
                                proxy: webViewProxy,
                                onScrollPositionChange: { fraction in
                                    scrollFraction = fraction
                                },
                                onPageInfo: { current, total in
                                    currentPage = current
                                    totalPages = total
                                },
                                onToggleChrome: {
                                    showChrome.toggle()
                                }
                            )
                        } else {
                            scrollingTextView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                        viewWidth = newWidth
                    }
                    .onChange(of: geometry.size.height, initial: true) { _, newHeight in
                        viewHeight = newHeight
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            handleKeyRepeat(event.phase)
            webViewProxy.previousPage?()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            handleKeyRepeat(event.phase)
            webViewProxy.nextPage?()
            return .handled
        }
        #if os(iOS)
        .background(safeAreaBackground.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .automatic)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: Binding(
            get: { showTOC && sizeClass == .compact },
            set: { if !$0 { showTOC = false } }
        )) {
            NavigationStack {
                textSidebar
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showTOC = false }
                        }
                    }
            }
        }
        #endif
        .preferredColorScheme(effective.theme.preferredColorScheme)
        .onKeyPress(.escape) {
            if showSearch { dismissTextSearch(); return .handled }
            #if os(iOS)
            if !showChrome { showChrome = true; return .handled }
            #endif
            return .ignored
        }
        .overlay(alignment: .top) {
            if showSearch {
                SearchBarView(
                    query: $searchQuery,
                    isSearching: $isSearching,
                    resultCount: searchMatchOffsets.count,
                    currentResult: searchMatchOffsets.isEmpty ? 0 : currentSearchIndex + 1,
                    onNext: { navigateTextSearchResult(forward: true) },
                    onPrevious: { navigateTextSearchResult(forward: false) },
                    onDismiss: { dismissTextSearch() }
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
                        readAloud.dismiss()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    textProgressSlider
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            if showChrome {
                textProgressSlider
            }
        }
        #endif
    }

    private var statusLabel: String {
        if isPaginated {
            return pageLabel
        }
        return ""
    }

    // MARK: - Scrolling Content

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
            Text(fileURL?.deletingPathExtension().lastPathComponent ?? "")
                .lineLimit(1)
            Spacer()
            Menu {
                Section {
                    Button { selectAutomatic() } label: { Label("Automatic", systemImage: "rectangle.portrait.and.arrow.right") }
                    Button { selectSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
                    Button { selectTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
                    Button { selectScrolling() } label: { Label("Scrolling", systemImage: "scroll") }
                }
                Section {
                    if isMarkdown {
                        Button { renderMarkdown.toggle() } label: {
                            Label(renderMarkdown ? "Raw Text" : "Render Markdown",
                                  systemImage: renderMarkdown ? "doc.plaintext" : "doc.richtext")
                        }
                    }
                    if !isMarkdown {
                        Button { toggleReflow() } label: {
                            Label(effective.reflowText ? "Preserve Line Breaks" : "Reflow Text",
                                  systemImage: effective.reflowText ? "text.justify.leading" : "text.word.spacing")
                        }
                    }
                    Button { showTOC.toggle() } label: {
                        Label("Sidebar", systemImage: showTOC ? "sidebar.leading" : "sidebar.left")
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { showSearch.toggle(); if !showSearch { dismissTextSearch() } } label: {
                        Label("Search", systemImage: "magnifyingglass")
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
    private var textProgressSlider: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { scrollFraction },
                    set: { newValue in
                        if isPaginated {
                            let page = Int(newValue * Double(max(1, totalPages - 1)))
                            webViewProxy.goToPageImmediate?(page)
                        } else {
                            scrollFraction = newValue
                            scrollTarget = Int(newValue * Double(max(1, cachedTextChunks.count - 1)))
                        }
                    }
                ),
                in: 0...1
            )
            .padding(.horizontal)
            .padding(.top, 6)
            HStack {
                Text(statusLabel).font(.caption).monospacedDigit()
                Spacer()
                Text("\(Int(scrollFraction * 100))%").font(.caption).monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// Chunked lazy text rendering for scrolling mode (raw text only).
    private var scrollingTextView: some View {
        let chunks = cachedTextChunks
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks.indices, id: \.self) { index in
                        Text(chunks[index])
                            .font(effective.swiftUIFont)
                            .lineSpacing((effective.lineSpacing - 1.0) * effective.fontSize)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .onAppear {
                                guard chunks.count > 1 else { return }
                                scrollFraction = Double(index) / Double(chunks.count - 1)
                            }
                    }
                }
                .padding(.horizontal, effective.marginsOneUp.leftRight)
                .padding(.vertical, effective.marginsOneUp.topBottom)
                .foregroundStyle(effective.foregroundColor ?? .primary)
            }
            .background(effective.backgroundColor ?? Color.clear)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { showChrome.toggle() }
            )
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                scrollTarget = nil
            }
            .task {
                restoreScrollPosition(chunks: chunks)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var textSidebar: some View {
        let tocEntries = markdownTOCEntries
        let bookmarks = bookmarkStore.bookmarks(for: fileHash ?? "")
        List {
            if isMarkdown && !tocEntries.isEmpty {
                Section("Contents") {
                    ForEach(tocEntries) { entry in
                        Button {
                            navigateToHeading(entry)
                            if sizeClass == .compact { showTOC = false }
                        } label: {
                            Text(entry.title)
                                .padding(.leading, CGFloat(entry.level - 1) * 16)
                                .fontWeight(entry.level <= 2 ? .semibold : .regular)
                                .font(entry.level == 1 ? .body : .callout)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Bookmarks") {
                if bookmarks.isEmpty {
                    Text("No bookmarks yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            navigateToBookmark(bookmark)
                            if sizeClass == .compact { showTOC = false }
                        } label: {
                            Label(bookmark.position.displayString, systemImage: "bookmark.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func navigateToBookmark(_ bookmark: BookmarkEntry) {
        guard case .textOffset(let offset) = bookmark.position else { return }
        let fraction = Double(offset) / 1000.0
        if isPaginated {
            let page = max(0, Int(round(fraction * Double(totalPages - 1))))
            webViewProxy.goToPage?(page)
        } else {
            let chunks = cachedTextChunks
            let targetIndex = min(Int(round(fraction * Double(chunks.count - 1))), chunks.count - 1)
            scrollTarget = targetIndex
        }
    }

    private func navigateToHeading(_ heading: MarkdownHeading) {
        if useWebView {
            webViewProxy.goToAnchor?(heading.id)
        } else {
            // Scroll to the chunk containing this heading's line
            let chunkIndex = heading.lineIndex / 100
            scrollTarget = min(chunkIndex, max(cachedTextChunks.count - 1, 0))
        }
    }

    /// Restore scroll position from auto-saved position or bookmark.
    private func restoreScrollPosition(chunks: [String]) {
        let offset: Int
        if let hash = fileHash,
           let autoSaved = bookmarkStore.savedPosition(for: hash),
           case .textOffset(let off) = autoSaved.position {
            offset = off
        } else if let mostRecent = bookmarkStore.bookmarks(for: fileHash ?? "").first,
                  case .textOffset(let off) = mostRecent.position {
            offset = off
        } else {
            return
        }
        let fraction = Double(offset) / 1000.0
        if isPaginated {
            let page = max(0, Int(round(fraction * Double(totalPages - 1))))
            scrollFraction = fraction
            webViewProxy.goToPage?(page)
        } else {
            let targetIndex = min(Int(round(fraction * Double(chunks.count - 1))), chunks.count - 1)
            if targetIndex > 0 {
                scrollTarget = targetIndex
            }
        }
    }

    // MARK: - Toolbar

    private var currentModeIcon: String {
        if !isPaginated { return "scroll.fill" }
        if effectiveTwoUp { return "rectangle.split.2x1.fill" }
        return "rectangle.fill"
    }

    @ToolbarContentBuilder
    private var textToolbar: some ToolbarContent {
        if sizeClass == .compact {
            // iPhone: single menu with all actions
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section {
                        Button { selectAutomatic() } label: { Label("Automatic", systemImage: "rectangle.portrait.and.arrow.right") }
                        Button { selectSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
                        Button { selectTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
                        Button { selectScrolling() } label: { Label("Scrolling", systemImage: "scroll") }
                    }
                    Section {
                        if isMarkdown {
                            Button { renderMarkdown.toggle() } label: {
                                Label(renderMarkdown ? "Raw Text" : "Render Markdown",
                                      systemImage: renderMarkdown ? "doc.plaintext" : "doc.richtext")
                            }
                        }
                        if !isMarkdown {
                            Button { toggleReflow() } label: {
                                Label(effective.reflowText ? "Preserve Line Breaks" : "Reflow Text",
                                      systemImage: effective.reflowText ? "text.justify.leading" : "text.word.spacing")
                            }
                        }
                        Button { showTOC.toggle() } label: {
                            Label("Sidebar", systemImage: showTOC ? "sidebar.leading" : "sidebar.left")
                        }
                        Button { toggleBookmark() } label: {
                            Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                                  systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        Button { showSearch.toggle(); if !showSearch { dismissTextSearch() } } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    #if os(iOS) || os(visionOS)
                    Section {
                        Button { toggleReadAloud() } label: {
                            Label(readAloud.isActive ? "Stop Read Aloud" : "Read Aloud",
                                  systemImage: readAloud.isActive ? "speaker.slash" : "speaker.wave.2")
                        }
                    }
                    #endif
                    Section {
                        Button { showSettings = true } label: { Label("Reading Settings", systemImage: "textformat.size") }
                        Button { showBookmarks = true } label: { Label("Go to Bookmark...", systemImage: "bookmark") }
                    }
                } label: {
                    Label("Menu", systemImage: "ellipsis.circle")
                }
            }
        } else {
            // Mac / iPad: full toolbar
            if isPaginated {
                ToolbarItemGroup(placement: .automatic) {
                    Button { webViewProxy.previousPage?() } label: {
                        Label("Previous Page", systemImage: "chevron.left")
                    }
                    .disabled(currentPage <= 0)

                    Button { webViewProxy.nextPage?() } label: {
                        Label("Next Page", systemImage: "chevron.right")
                    }
                    .disabled(currentPage >= totalPages - 1)
                }
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Button { selectAutomatic() } label: { Label("Automatic", systemImage: "rectangle.portrait.and.arrow.right") }
                    Button { selectSinglePage() } label: { Label("Single Page", systemImage: "rectangle") }
                    Button { selectTwoPage() } label: { Label("Two Pages", systemImage: "rectangle.split.2x1") }
                    Button { selectScrolling() } label: { Label("Scrolling", systemImage: "scroll") }
                } label: {
                    Label("View Mode", systemImage: currentModeIcon)
                }
            }

            if isMarkdown {
                ToolbarItem(placement: .automatic) {
                    Button { renderMarkdown.toggle() } label: {
                        Label(renderMarkdown ? "Raw Text" : "Render Markdown",
                              systemImage: renderMarkdown ? "doc.plaintext" : "doc.richtext")
                    }
                }
            }

            if !isMarkdown {
                ToolbarItem(placement: .automatic) {
                    Button { toggleReflow() } label: {
                        Label(effective.reflowText ? "Preserve Line Breaks" : "Reflow Text",
                              systemImage: effective.reflowText ? "text.justify.leading" : "text.word.spacing")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Button { showTOC.toggle() } label: {
                    Label("Sidebar", systemImage: showTOC ? "sidebar.leading" : "sidebar.left")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button { toggleBookmark() } label: {
                    Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button { showSearch.toggle(); if !showSearch { dismissTextSearch() } } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }

            #if os(iOS) || os(visionOS)
            ToolbarItem(placement: .automatic) {
                Button { toggleReadAloud() } label: {
                    Label(readAloud.isActive ? "Stop Read Aloud" : "Read Aloud",
                          systemImage: readAloud.isActive ? "speaker.slash" : "speaker.wave.2")
                }
            }
            #endif

            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: {
                    Label("Reading Settings", systemImage: "textformat.size")
                }
            }
        }
    }

    // MARK: - Search

    private func performTextSearch(_ query: String) {
        guard !query.isEmpty else {
            searchMatchOffsets = []
            currentSearchIndex = 0
            isSearching = false
            return
        }
        isSearching = true
        let text = rawText
        let lowered = text.lowercased()
        let needle = query.lowercased()
        var ranges: [Range<String.Index>] = []
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        searchMatchOffsets = ranges
        currentSearchIndex = 0
        isSearching = false
        if !ranges.isEmpty {
            scrollToSearchMatch(at: 0)
        }
    }

    private func navigateTextSearchResult(forward: Bool) {
        guard !searchMatchOffsets.isEmpty else { return }
        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchMatchOffsets.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchMatchOffsets.count) % searchMatchOffsets.count
        }
        scrollToSearchMatch(at: currentSearchIndex)
    }

    private func scrollToSearchMatch(at index: Int) {
        guard index < searchMatchOffsets.count else { return }
        let matchRange = searchMatchOffsets[index]
        let text = rawText
        let offset = text.distance(from: text.startIndex, to: matchRange.lowerBound)
        let totalLength = text.count
        guard totalLength > 0 else { return }

        if useWebView {
            // For WebView mode, use JS window.find() or scroll by fraction
            let fraction = Double(offset) / Double(totalLength)
            let page = max(0, Int(round(fraction * Double(totalPages - 1))))
            webViewProxy.goToPage?(page)
        } else {
            // Scroll to the chunk containing this match
            let lines = text.prefix(upTo: matchRange.lowerBound).components(separatedBy: "\n")
            let chunkIndex = lines.count / 100
            let chunks = cachedTextChunks
            scrollTarget = min(chunkIndex, max(chunks.count - 1, 0))
        }
    }

    private func dismissTextSearch() {
        showSearch = false
        searchQuery = ""
        searchMatchOffsets = []
        currentSearchIndex = 0
        isSearching = false
    }

    private var pageLabel: String {
        if effectiveTwoUp && currentPage + 1 < totalPages {
            return "Pg \(currentPage + 1)–\(currentPage + 2)/\(totalPages)"
        }
        return "Pg \(currentPage + 1)/\(totalPages)"
    }

    private var isCurrentPositionBookmarked: Bool {
        guard let hash = fileHash else { return false }
        return bookmarkStore.isPositionBookmarked(fileHash: hash, position: .textOffset(Int(scrollFraction * 1000)))
    }

    private func toggleBookmark() {
        guard let url = fileURL, let hash = fileHash else { return }
        let position: ReadingPosition = .textOffset(Int(scrollFraction * 1000))
        if let existing = bookmarkStore.bookmarkAt(fileHash: hash, position: position) {
            bookmarkStore.removeBookmark(id: existing.id)
        } else {
            bookmarkStore.addBookmark(position, for: url, data: rawData)
        }
    }

    private func autoSavePosition() {
        guard let url = fileURL else { return }
        guard scrollFraction > 0 else { return }
        let position: ReadingPosition = .textOffset(Int(scrollFraction * 1000))
        bookmarkStore.savePosition(position, for: url, data: rawData)
    }

    private func adjustFontSize(by delta: Double) {
        let newSize = max(12, min(36, readingPrefs.effective(for: fileHash).fontSize + delta))
        readingPrefs.updatePreference(for: fileHash, apply: { $0.fontSize = newSize }, applyGlobal: { readingPrefs.fontSize = newSize })
    }

    // MARK: - Key repeat quick vanish

    private func handleKeyRepeat(_ phase: KeyPress.Phases) {
        if phase == .down {
            keyRepeatCount = 0
        }
        keyRepeatCount += 1
        resetFastScrollTimer()
    }

    private func resetFastScrollTimer() {
        fastScrollTimer?.invalidate()
        fastScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                keyRepeatCount = 0
            }
        }
    }

    private func selectAutomatic() {
        viewMode = .paginated
        twoUpOverride = nil
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .paginated; $0.twoUp = nil }, applyGlobal: { readingPrefs.viewMode = .paginated })
    }

    private func selectSinglePage() {
        viewMode = .paginated
        twoUpOverride = false
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .paginated; $0.twoUp = false }, applyGlobal: { readingPrefs.viewMode = .paginated })
    }

    private func selectTwoPage() {
        viewMode = .paginated
        twoUpOverride = true
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .paginated; $0.twoUp = true }, applyGlobal: { readingPrefs.viewMode = .paginated })
    }

    private func selectScrolling() {
        viewMode = .scrolling
        readingPrefs.updatePreference(for: fileHash, apply: { $0.viewMode = .scrolling; $0.twoUp = nil }, applyGlobal: { readingPrefs.viewMode = .scrolling })
    }

    private func toggleReflow() {
        let newValue = !effective.reflowText
        readingPrefs.updatePreference(for: fileHash, apply: { $0.reflowText = newValue }, applyGlobal: { readingPrefs.reflowText = newValue })
    }

    // MARK: - Read Aloud (iOS only)

    #if os(iOS) || os(visionOS)
    private func toggleReadAloud() {
        if readAloud.isActive {
            readAloud.dismiss()
            return
        }
        let text: String
        if isMarkdown {
            text = ReadAloudController.stripMarkdown(rawText)
        } else {
            text = rawText
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let startOffset = Int(scrollFraction * Double(text.count))

        readAloud.loadText(text, startOffset: startOffset)
        readAloud.onWordRange = { _ in }
        readAloud.onSectionFinished = { [weak readAloud] in
            readAloud?.dismiss()
        }
        readAloud.play()
    }
    #endif

    // MARK: - HTML Generation

    /// Creates a temporary HTML file for WebView display.
    /// Uses markdown-to-HTML conversion when rendering is enabled, otherwise escaped plain text.
    private func prepareHTMLFile() {
        var text = rawText
        if effective.reflowText && !isMarkdown {
            text = TextReflow.reflow(text)
        }
        let bodyContent: String

        if isMarkdown && renderMarkdown {
            bodyContent = markdownToHTML(text)
        } else {
            let escaped = escapeHTML(text)
            bodyContent = "<p>" + escaped
                .replacingOccurrences(of: "\n\n", with: "</p><p>")
                .replacingOccurrences(of: "\n", with: "<br>")
                + "</p>"
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body {
            background-color: #ffffff;
            color: #000000;
            margin: 0;
            padding: 16px;
            word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 1em; margin-bottom: 0.5em; }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.3em; }
        h4 { font-size: 1.1em; }
        pre { background: #f4f4f4; padding: 12px; border-radius: 4px; overflow-x: auto; }
        code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em; }
        :not(pre) > code { background: #f0f0f0; padding: 2px 4px; border-radius: 3px; }
        blockquote {
            border-left: 3px solid #ccc;
            margin: 0.5em 0;
            padding: 0.25em 1em;
            color: #555;
        }
        hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
        img { max-width: 100%; height: auto; }
        a { color: #0066cc; }
        </style>
        </head><body>\(bodyContent)</body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-text-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("content.html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        htmlFileURL = file
        htmlBaseURL = dir
    }

    // MARK: - Markdown to HTML

    /// Converts markdown text to HTML with block-level and inline element support.
    /// Injects anchor IDs on headers matching the TOC entry indices.
    private func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html: [String] = []
        var i = 0
        var headerIndex = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block (fenced)
            if trimmed.hasPrefix("```") {
                i += 1
                var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escapeHTML(lines[i]))
                    i += 1
                }
                html.append("<pre><code>" + code.joined(separator: "\n") + "</code></pre>")
                if i < lines.count { i += 1 }
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                html.append("<hr>")
                i += 1
                continue
            }

            // Header — inject anchor ID for TOC navigation
            if let (level, text) = parseHeader(trimmed) {
                let anchorId = "toc-\(headerIndex)"
                headerIndex += 1
                html.append("<h\(level) id=\"\(anchorId)\">" + processInline(text) + "</h\(level)>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quoteLines.append(String(t.dropFirst(2)))
                    } else if t == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                html.append("<blockquote>" + quoteLines.map { processInline($0) }.joined(separator: "<br>") + "</blockquote>")
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                html.append("<ul>")
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isUnorderedListItem(t) {
                        html.append("<li>" + processInline(String(t.dropFirst(2))) + "</li>")
                        i += 1
                    } else if t.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                html.append("</ul>")
                continue
            }

            // Ordered list
            if let itemText = parseOrderedListItem(trimmed) {
                html.append("<ol>")
                html.append("<li>" + processInline(itemText) + "</li>")
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let text = parseOrderedListItem(t) {
                        html.append("<li>" + processInline(text) + "</li>")
                        i += 1
                    } else if t.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                html.append("</ol>")
                continue
            }

            // Regular paragraph — collect consecutive non-empty, non-block lines
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { i += 1; break }
                if t.hasPrefix("```") || t.hasPrefix("# ") || t.hasPrefix("## ")
                    || t.hasPrefix("### ") || t.hasPrefix("> ") || t == ">"
                    || isUnorderedListItem(t) || parseOrderedListItem(t) != nil
                    || isHorizontalRule(t) { break }
                paraLines.append(processInline(t))
                i += 1
            }
            if !paraLines.isEmpty {
                html.append("<p>" + paraLines.joined(separator: " ") + "</p>")
            }
        }

        return html.joined(separator: "\n")
    }

    // MARK: - Markdown Helpers

    private func parseHeader(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...])
        return (level, text)
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3 else { return false }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    private func isUnorderedListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private func parseOrderedListItem(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    /// Process inline markdown: code spans, bold, italic, links, images.
    private func processInline(_ text: String) -> String {
        var result = escapeHTML(text)

        // Extract code spans first (to prevent styling inside code)
        var codeSpans: [String] = []
        while let range = result.range(of: "`([^`]+)`", options: .regularExpression) {
            let match = String(result[range])
            let inner = String(match.dropFirst().dropLast())
            let placeholder = "\u{FFFC}CODE\(codeSpans.count)\u{FFFC}"
            codeSpans.append(inner)
            result.replaceSubrange(range, with: placeholder)
        }

        // Bold (must come before italic)
        result = replacePattern(result, pattern: "\\*\\*(.+?)\\*\\*", template: "<strong>$1</strong>")
        result = replacePattern(result, pattern: "__(.+?)__", template: "<strong>$1</strong>")

        // Italic
        result = replacePattern(result, pattern: "\\*(.+?)\\*", template: "<em>$1</em>")
        result = replacePattern(result, pattern: "(?<![\\w])_(.+?)_(?![\\w])", template: "<em>$1</em>")

        // Images (before links)
        result = replacePattern(result, pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", template: "<img alt=\"$1\" src=\"$2\">")

        // Links
        result = replacePattern(result, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", template: "<a href=\"$2\">$1</a>")

        // Restore code spans
        for (idx, span) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: "\u{FFFC}CODE\(idx)\u{FFFC}", with: "<code>\(span)</code>")
        }

        return result
    }

    private func replacePattern(_ input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
