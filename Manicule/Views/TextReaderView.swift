import SwiftUI
import AVFoundation

/// Displays plain text or Markdown.
/// Scrolling mode uses a chunked LazyVStack for raw text, or WebView for rendered markdown.
/// Paginated mode uses WebViewRepresentable for both raw and rendered content.
struct TextReaderView: View {
    let content: TextContent
    let fileURL: URL?
    let rawData: Data
    @Environment(\.readingSession) private var readingSession
    let fileHash: String
    @Binding var showChrome: Bool
    var onClose: (() -> Void)?

    @State private var textAnchor: TextAnchor?
    @State private var chunkSourceLines: [Int] = []
    private enum NativeRestoration {
        case waitingForChunks, waitingForChunk(Int), ready
    }
    @State private var nativeRestoration = NativeRestoration.waitingForChunks
    @State private var chunkFrames: [Int: CGRect] = [:]
    @State private var scrollFraction: Double = 0.0
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 1
    @State private var showBookmarks: Bool = false
    @State private var showSettings: Bool = false
    private var viewMode: ViewMode { effective.viewMode }
    private var twoUpOverride: Bool? { effective.twoUp }
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @State private var webViewProxy = WebViewProxy()
    @State private var htmlDirectory: TemporaryDirectoryLease?
    @State private var renderError: String?
    @State private var renderAttempt = UUID()
    private var htmlBaseURL: URL? { htmlDirectory?.url }
    private var htmlFileURL: URL? { htmlBaseURL?.appendingPathComponent("content.html") }
    @State private var scrollTarget: Int? = nil
    @State private var cachedTextChunks: [String] = []
    @State private var renderMarkdown: Bool = false
    @State private var showTOC: Bool = false

    @State private var fastScroll = FastScrollController()

    // Read-aloud state (iOS only)
    #if os(iOS) || os(visionOS)
    private let readAloud = ReadAloudController.shared
    @State private var narrationOwner = UUID()
    private var ownsNarration: Bool { readAloud.owner == narrationOwner }
    private var narrationIsActive: Bool { ownsNarration && readAloud.isActive }
    #endif

    // Search state
    @State private var search = ReaderSearchState()
    @State private var searchMatches: [TextSearch.Match] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncer = SearchDebouncer()

    @Environment(\.horizontalSizeClass) private var sizeClass

    private let bookmarkStore = BookmarkStore.shared
    private let readingPrefs = ReadingPreferences.shared

    private var effective: EffectivePreferences {
        readingPrefs.effective(for: fileHash)
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
            if let (level, text) = MarkdownHTMLRenderer.parseHeading(trimmed) {
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
                    BookmarkPickerView(fileHash: fileHash) { position in
                        navigateToPosition(position)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ReaderSettingsSheet(fileHash: fileHash, showReflowOption: !isMarkdown)
            }
            .alert("Unable to Render Text", isPresented: Binding(
                get: { renderError != nil },
                set: { if !$0 { renderError = nil } }
            )) {
                Button("Retry") { renderAttempt = UUID() }
                Button("OK", role: .cancel) { renderError = nil }
            } message: {
                Text(renderError ?? "")
            }
            .task(id: "\(renderMarkdown)-\(effective.reflowText)-\(renderAttempt)") {
                await prepareText()
            }
            .task {
                ReaderHelpers.migrateLegacyIdentity(data: rawData, currentHash: fileHash)
                readingPrefs.touchLastUsed(for: fileHash)
                // Restore saved scroll fraction before WebView renders,
                // so the initial WebViewContent gets the correct position.
                if let saved = bookmarkStore.savedPosition(for: fileHash) {
                    scrollFraction = saved.position.textFraction ?? 0
                    textAnchor = saved.position.textAnchor
                }
                renderMarkdown = isMarkdown
            }
            .onDisappear {
                autoSavePosition()
                searchDebouncer.cancel()
                clearTextSearch()
                htmlDirectory = nil
                #if os(iOS) || os(visionOS)
                readAloud.dismiss(for: narrationOwner)
                #endif
            }
            .task(id: currentPosition) {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                autoSavePosition()
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
            .readerCommands(ReaderCommandHandlers(
                onToggleViewMode: { if isPaginated { selectScrolling() } else { selectSinglePage() } },
                onBookmark: toggleBookmark,
                onShowSavedPositions: { showBookmarks = true },
                onShowReadingSettings: { showSettings = true },
                onToggleSearch: {
                    search.isShowing.toggle()
                    if !search.isShowing { dismissTextSearch() }
                },
                onToggleImmersive: { showChrome.toggle() },
                onZoomIn: { adjustFontSize(by: 1) },
                onZoomOut: { adjustFontSize(by: -1) }
            ))
            .onReaderCommand(.toggleTableOfContents) {
                showTOC.toggle()
            }
            #if os(iOS) || os(visionOS)
            .onReaderCommand(.toggleReadAloud, perform: toggleReadAloud)
            #endif
            .onChange(of: search.query) { _, newQuery in
                clearTextSearch()
                searchDebouncer.handle(newQuery, perform: performTextSearch, clear: clearTextSearch)
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
                Group {
                    if useWebView, let generatedURL = htmlFileURL, let baseURL = htmlBaseURL {
                        WebViewRepresentable(
                            content: WebViewContent(
                                fileURL: generatedURL,
                                baseURL: baseURL,
                                scrollFraction: scrollFraction > 0 ? scrollFraction : nil,
                                fragment: nil,
                                cssOverride: effective.cssString,
                                paginated: isPaginated,
                                twoUp: isPaginated ? ReaderHelpers.resolveTwoUpForBridge(twoUpOverride) : nil,
                                resourceBaseURL: isMarkdown && renderMarkdown
                                    ? self.fileURL?.deletingLastPathComponent() : nil,
                                marginsOneUp: effective.marginsOneUp,
                                marginsTwoUp: effective.marginsTwoUp,
                                resourceLease: htmlDirectory,
                                textAnchor: textAnchor
                            ),
                            proxy: webViewProxy,
                            onScrollPositionChange: { fraction in
                                scrollFraction = min(1, max(0, fraction.isFinite ? fraction : 0))
                            },
                            onTextAnchorChange: { textAnchor = $0 },
                            onPageInfo: { current, total in
                                currentPage = current
                                totalPages = total
                            },
                            onToggleChrome: {
                                showChrome.toggle()
                            },
                            onFailure: { renderError = $0 }
                        )
                    } else {
                        scrollingTextView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .trackViewportSize(width: $viewWidth, height: $viewHeight)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            fastScroll.handle(phase: event.phase)
            webViewProxy.previousPage?()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in
            guard isPaginated else { return .ignored }
            fastScroll.handle(phase: event.phase)
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
        .escapeDismisses(
            searchShowing: { search.isShowing },
            dismissSearch: dismissTextSearch,
            showChrome: $showChrome
        )
        .overlay(alignment: .top) {
            if search.isShowing {
                SearchBarView(
                    query: $search.query,
                    isSearching: $search.isSearching,
                    resultCount: searchMatches.count,
                    currentResult: searchMatches.isEmpty ? 0 : search.currentIndex + 1,
                    onNext: { navigateTextSearchResult(forward: true) },
                    onPrevious: { navigateTextSearchResult(forward: false) },
                    onDismiss: { dismissTextSearch() },
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
                        readAloud.dismiss(for: narrationOwner)
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
            HStack(spacing: 16) {
                if sizeClass != .compact {
                    Button {
                        withAnimation { showTOC.toggle() }
                    } label: {
                        Label(
                            showTOC ? "Hide Sidebar" : "Show Sidebar",
                            systemImage: "sidebar.leading"
                        )
                    }
                    .labelStyle(.iconOnly)
                }

                if let onClose {
                    if narrationIsActive {
                        Button {
                            readAloud.dismiss(for: narrationOwner)
                        } label: {
                            Label("Done", systemImage: "speaker.wave.2.fill")
                        }
                    } else {
                        Button("Close Book", action: onClose)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(fileURL?.deletingPathExtension().lastPathComponent ?? "")
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
                    Button { withAnimation { showTOC.toggle() } } label: {
                        Label(
                            showTOC ? "Hide Sidebar" : "Show Sidebar",
                            systemImage: "sidebar.leading"
                        )
                    }
                    Button { toggleBookmark() } label: {
                        Label(isCurrentPositionBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button { search.isShowing.toggle(); if !search.isShowing { dismissTextSearch() } } label: {
                        Label("Search", systemImage: "magnifyingglass")
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
    private var textProgressSlider: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { scrollFraction },
                    set: { newValue in
                        if isPaginated {
                            let page = Int(newValue * Double(max(1, totalPages - 1)))
                            webViewProxy.goToPageImmediate?(page)
                        } else if useWebView {
                            webViewProxy.restoreTextScroll?(newValue)
                        } else {
                            scrollFraction = newValue
                            scrollTarget = Int(newValue * Double(max(0, cachedTextChunks.count - 1)))
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
                            .onGeometryChange(for: CGRect.self) { geometry in
                                geometry.frame(in: .named("readerText"))
                            } action: { frame in
                                chunkFrames[index] = frame
                                updateNativePosition()
                            }
                    }
                }
                .padding(.horizontal, effective.marginsOneUp.leftRight)
                .padding(.vertical, effective.marginsOneUp.topBottom)
                .foregroundStyle(effective.foregroundColor ?? .primary)
            }
            .coordinateSpace(name: "readerText")
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
            .task(id: chunkSourceLines) {
                guard !chunks.isEmpty else { return }
                restoreScrollPosition(chunks: chunks)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var textSidebar: some View {
        let tocEntries = markdownTOCEntries
        let bookmarks = bookmarkStore.bookmarks(for: fileHash)
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

    private var currentPosition: ReadingPosition {
        if let textAnchor { return .textAnchor(textAnchor, fraction: scrollFraction) }
        return .textOffset(Int(scrollFraction * 1000))
    }

    private func navigateToBookmark(_ bookmark: BookmarkEntry) {
        navigateToPosition(bookmark.position)
    }

    private func navigateToPosition(_ position: ReadingPosition) {
        guard let fraction = position.textFraction else { return }
        scrollFraction = fraction
        textAnchor = position.textAnchor
        if useWebView {
            if let anchor = textAnchor { webViewProxy.goToTextAnchor?(anchor) }
            else if isPaginated { webViewProxy.goToPage?(Int(round(fraction * Double(max(0, totalPages - 1))))) }
            else { webViewProxy.restoreTextScroll?(fraction) }
        } else {
            let target = textAnchor.flatMap { anchor in chunkSourceLines.lastIndex(where: { $0 <= anchor.line }) }
                ?? Int(round(fraction * Double(max(0, cachedTextChunks.count - 1))))
            nativeRestoration = .waitingForChunk(target)
            scrollTarget = target
        }
    }

    private func updateNativePosition() {
        guard !useWebView,
              let index = chunkFrames.filter({ $0.value.maxY > 0 && $0.value.minY < viewHeight })
                .min(by: { $0.value.minY < $1.value.minY })?.key,
              chunkSourceLines.indices.contains(index), cachedTextChunks.indices.contains(index) else { return }
        switch nativeRestoration {
        case .waitingForChunks: return
        case .waitingForChunk(let target) where index != target: return
        default: nativeRestoration = .ready
        }
        textAnchor = TextAnchor(line: chunkSourceLines[index], quote: String(cachedTextChunks[index].prefix(80)))
        scrollFraction = cachedTextChunks.count > 1 ? Double(index) / Double(cachedTextChunks.count - 1) : 0
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
        if textAnchor != nil { navigateToPosition(currentPosition) }
        else if let position = bookmarkStore.savedPosition(for: fileHash)?.position
            ?? bookmarkStore.bookmarks(for: fileHash).first?.position {
            navigateToPosition(position)
        } else {
            navigateToPosition(.textOffset(0))
        }
    }

    // MARK: - Toolbar

    private var currentModeIcon: String {
        ReaderHelpers.viewModeIcon(isPaginated: isPaginated, twoUpOverride: twoUpOverride)
    }

    @ToolbarContentBuilder
    private var textToolbar: some ToolbarContent {
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
            Button { search.isShowing.toggle(); if !search.isShowing { dismissTextSearch() } } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button { showSettings = true } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
        }
    }

    // MARK: - Search

    private func performTextSearch(_ query: String) {
        clearTextSearch()
        search.isSearching = true
        let source = rawText
        let reflow = effective.reflowText && !isMarkdown
        searchTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                let text = reflow ? TextReflow.reflow(source) : source
                return try TextSearch.matches(in: text, query: query)
            }
            do {
                let matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                searchMatches = matches
                search.isSearching = false
                if !matches.isEmpty { scrollToSearchMatch(at: 0) }
            } catch {
                guard !Task.isCancelled else { return }
                search.isSearching = false
            }
        }
    }

    private func clearTextSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchMatches = []
        search.currentIndex = 0
        search.isSearching = false
    }

    private func navigateTextSearchResult(forward: Bool) {
        guard !searchMatches.isEmpty else { return }
        if forward {
            search.currentIndex = (search.currentIndex + 1) % searchMatches.count
        } else {
            search.currentIndex = (search.currentIndex - 1 + searchMatches.count) % searchMatches.count
        }
        scrollToSearchMatch(at: search.currentIndex)
    }

    private func scrollToSearchMatch(at index: Int) {
        guard index < searchMatches.count else { return }
        let match = searchMatches[index]
        if useWebView {
            let page = max(0, Int(round(match.fraction * Double(totalPages - 1))))
            webViewProxy.goToPage?(page)
        } else {
            scrollTarget = min(match.chunk, max(cachedTextChunks.count - 1, 0))
        }
    }

    private func dismissTextSearch() {
        searchDebouncer.cancel()
        clearTextSearch()
        search.reset()
    }

    private var pageLabel: String {
        if effectiveTwoUp && currentPage + 1 < totalPages {
            return "Pg \(currentPage + 1)–\(currentPage + 2)/\(totalPages)"
        }
        return "Pg \(currentPage + 1)/\(totalPages)"
    }

    private var isCurrentPositionBookmarked: Bool {
        return bookmarkStore.isPositionBookmarked(fileHash: fileHash, position: currentPosition)
    }

    private func toggleBookmark() {
        guard let url = fileURL else { return }
        let position = currentPosition
        if let existing = bookmarkStore.bookmarkAt(fileHash: fileHash, position: position) {
            bookmarkStore.removeBookmark(id: existing.id)
        } else {
            bookmarkStore.addBookmark(position, for: url, data: rawData, fileHash: fileHash)
        }
    }

    private func autoSavePosition() {
        guard let url = fileURL else { return }
        guard htmlDirectory != nil else { return }
        let position = currentPosition
        bookmarkStore.savePosition(position, for: url, data: rawData, fileHash: fileHash, session: readingSession)
    }

    private func adjustFontSize(by delta: Double) {
        let newSize = max(12, min(36, readingPrefs.effective(for: fileHash).fontSize + delta))
        readingPrefs.updatePreference(for: fileHash, apply: { $0.fontSize = newSize }, applyGlobal: { readingPrefs.fontSize = newSize })
    }

    // MARK: - Key repeat quick vanish


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

    private func toggleReflow() {
        let newValue = !effective.reflowText
        readingPrefs.updatePreference(for: fileHash, apply: { $0.reflowText = newValue }, applyGlobal: { readingPrefs.reflowText = newValue })
    }

    // MARK: - Read Aloud (iOS only)

    #if os(iOS) || os(visionOS)
    private func toggleReadAloud() {
        if narrationIsActive {
            readAloud.dismiss(for: narrationOwner)
            return
        }
        let text: String
        if isMarkdown {
            text = ReadAloudController.stripMarkdown(rawText)
        } else {
            text = rawText
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // UTF-16 offset — ReadAloudController tracks positions in UTF-16 units.
        let startOffset = Int(scrollFraction * Double((text as NSString).length))

        readAloud.claim(for: narrationOwner)
        readAloud.loadText(text, startOffset: startOffset)
        readAloud.onWordRange = { _ in }
        readAloud.onSectionFinished = { [weak readAloud] in
            readAloud?.dismiss(for: narrationOwner)
        }
        readAloud.play()
    }
    #endif

    // MARK: - HTML Generation

    private func prepareText() async {
        let text = rawText
        let reflow = effective.reflowText && !isMarkdown
        let markdown = isMarkdown && renderMarkdown
        let hasFile = fileURL != nil
        let worker = Task.detached(priority: .userInitiated) {
            try TextPreparation.prepare(text, reflow: reflow, markdown: markdown, hasFile: hasFile)
        }
        do {
            let prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            nativeRestoration = .waitingForChunks
            chunkFrames = [:]
            cachedTextChunks = prepared.chunks
            chunkSourceLines = prepared.chunkSourceLines
            htmlDirectory = prepared.directory
            renderError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            renderError = error.localizedDescription
        }
    }
}
