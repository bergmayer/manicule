#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import FileProvider
import os.log

private let browserLog = Logger(subsystem: "com.palefire.manicule", category: "Browser")

private let sharedGroupID = "group.com.palefire.manicule"

/// Holds a successfully opened document and its source URL.
struct OpenedDocument: Equatable {
    let document: ReaderDocument
    let fileURL: URL
    let securityScoped: Bool

    static func == (lhs: OpenedDocument, rhs: OpenedDocument) -> Bool {
        lhs.fileURL == rhs.fileURL
    }
}

/// Root view for iOS: shows either the library or the document viewer.
struct IOSRootView: View {
    @State private var openedDocument: OpenedDocument?
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var showSettings: Bool = false
    @State private var isOpening: Bool = false
    @State private var activeOpenRequestID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let opened = openedDocument {
                NavigationStack {
                    DocumentViewer(
                        document: opened.document,
                        fileURL: opened.fileURL,
                        onClose: { closeDocument() }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                    // Fresh view identity per file. Without this, opening a
                    // document while another is showing (onOpenURL, shared
                    // file) reuses the reader's @State — stale pages, stale
                    // restore tasks, even the previous book's content.
                    .id(opened.fileURL)
                }
            } else {
                libraryView
            }
        }
        .onOpenURL { url in
            browserLog.info("onOpenURL: \(url.absoluteString, privacy: .public)")
            if url.scheme == "manicule" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    if url.host == "shared",
                       let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
                       let fileURL = URL(string: urlParam) {
                        clearPendingSharedFile()
                        beginOpeningDocument(at: fileURL)
                        return
                    }
                    let filename = components.queryItems?.first(where: { $0.name == "file" })?.value ?? ""
                    NotificationCenter.default.post(
                        name: .openFromQLPreview,
                        object: nil,
                        userInfo: filename.isEmpty ? nil : ["filename": filename]
                    )
                }
            } else if url.isFileURL {
                beginOpeningDocument(at: url)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { checkForPendingSharedFile() }
        }
        .alert("Unable to Open File", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: Binding(
            get: { pickerDirectoryURL != nil },
            set: { if !$0 { pickerDirectoryURL = nil; pickerFileName = nil } }
        )) {
            LocateFilePickerView(
                directoryURL: pickerDirectoryURL,
                fileName: pickerFileName,
                onOpen: { url in
                    pickerDirectoryURL = nil
                    pickerFileName = nil
                    beginOpeningDocument(at: url)
                }
            )
        }
        .sheet(isPresented: $showFilePicker) {
            LocateFilePickerView(
                directoryURL: nil,
                fileName: nil,
                onOpen: { url in beginOpeningDocument(at: url) }
            )
        }
        .sheet(isPresented: $showSettings) {
            IOSSettingsView()
        }
        .overlay {
            if isOpening {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    ProgressView("Opening…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
        .task { await FileProviderPrimer.startPrewarm() }
    }

    // MARK: - Library View

    private var libraryView: some View {
        let trackedBooks = BookmarkStore.shared.autoSavedPositions
            .sorted { $0.lastOpened > $1.lastOpened }

        return NavigationStack {
            Group {
                if trackedBooks.isEmpty {
                    emptyLibrary
                } else {
                    RecentsGridSection(
                        books: trackedBooks,
                        onTap: { entry in Task { await openRecentBook(entry) } },
                        onRemove: { entry in removeFromList(entry) }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showFilePicker = true } label: {
                        Image(systemName: "folder")
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("LaunchBackground")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 40))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)

            Button { showFilePicker = true } label: {
                HStack(spacing: 6) {
                    Text("Open a Book with the Document Picker")
                    Image(systemName: "folder")
                }
                .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func removeFromList(_ entry: AutoSavedPosition) {
        BookmarkStore.shared.removeSavedPosition(for: entry.id)
    }

    // MARK: - Open from Recents

    /// When non-nil, a document picker is presented pointing at this directory
    /// so the user can tap the file to grant access.
    @State private var pickerDirectoryURL: URL?
    @State private var pickerFileName: String?

    private func openRecentBook(_ entry: AutoSavedPosition) async {
        browserLog.info("openRecentBook: \(entry.fileName, privacy: .public), path=\(entry.filePathString ?? "nil", privacy: .public), hint=\(entry.relativePathHint ?? "nil", privacy: .public)")

        if await openUsingStoredAccess(entry) {
            return
        }

        // Present a document picker pointed at the file's parent folder.
        //    iOS requires the user to tap the file once to grant access.
        //    The picker opens in the right folder — one tap to open.
        if let dirURL = Self.parentDirectoryURL(for: entry) {
            browserLog.info("Presenting picker at \(dirURL.path, privacy: .public)")
            pickerFileName = entry.fileName
            pickerDirectoryURL = dirURL
            return
        }

        // No path info at all — open a general picker
        browserLog.info("No path info, presenting general picker")
        pickerFileName = entry.fileName
        pickerDirectoryURL = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/")
    }

    /// Build candidate file URLs from all synced path information.
    private static func candidateURLs(for entry: AutoSavedPosition) -> [URL] {
        var candidates: [URL] = []
        let mobileDocsBase = "/private/var/mobile/Library/Mobile Documents/"

        if let pathString = entry.filePathString {
            candidates.append(URL(fileURLWithPath: pathString))
        }

        if let hint = entry.relativePathHint {
            let reconstructed = URL(fileURLWithPath: mobileDocsBase + hint)
            if !candidates.contains(reconstructed) {
                candidates.append(reconstructed)
            }
        }

        let fileName = entry.fileName
        for subdir in ["com~apple~CloudDocs/Documents/", "com~apple~CloudDocs/"] {
            let url = URL(fileURLWithPath: mobileDocsBase + subdir + fileName)
            if !candidates.contains(url) {
                candidates.append(url)
            }
        }

        return candidates
    }

    /// Get the parent directory URL from synced path info.
    private static func parentDirectoryURL(for entry: AutoSavedPosition) -> URL? {
        if let pathString = entry.filePathString {
            return URL(fileURLWithPath: pathString).deletingLastPathComponent()
        }
        if let hint = entry.relativePathHint {
            let full = "/private/var/mobile/Library/Mobile Documents/" + hint
            return URL(fileURLWithPath: full).deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Document handling

    private func openUsingStoredAccess(_ entry: AutoSavedPosition) async -> Bool {
        if let url = BookmarkStore.shared.resolveURL(for: entry.id),
           await openDocument(at: url, showError: false) == nil {
            return true
        }

        if let ref = BookmarkStore.shared.fileProviderRef(for: entry.id),
           let url = await FileProviderPrimer.resolveFileProviderURL(ref, budget: .probe),
           await openDocument(at: url, showError: false) == nil {
            browserLog.info("FileProvider resolved to \(url.lastPathComponent, privacy: .public)")
            return true
        }

        for url in Self.candidateURLs(for: entry) {
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            if await openDocument(at: url, showError: false) == nil {
                browserLog.info("Direct access at \(url.path, privacy: .public)")
                return true
            }
        }

        return false
    }

    private func beginOpeningDocument(at url: URL) {
        Task { await openDocument(at: url) }
    }

    @discardableResult
    private func openDocument(at url: URL, showError: Bool = true) async -> Error? {
        let requestID = UUID()
        activeOpenRequestID = requestID
        isOpening = true
        defer {
            if activeOpenRequestID == requestID {
                activeOpenRequestID = nil
                isOpening = false
            }
        }

        let accessing = url.startAccessingSecurityScopedResource()
        browserLog.info("Opening \(url.lastPathComponent, privacy: .public), securityScoped=\(accessing)")

        do {
            let filename = url.lastPathComponent
            let (data, content, hash) = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let ext = url.pathExtension.lowercased()
                let contentType = UTType(filenameExtension: ext) ?? .data
                let content = try DocumentContent.parse(
                    data: data,
                    contentType: contentType,
                    filename: filename
                )
                return (data, content, FileHasher.hash(data: data))
            }.value

            // A second open request may have arrived while parsing. Never let
            // an older, slower archive replace the newer selection.
            guard activeOpenRequestID == requestID else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                return CancellationError()
            }

            let doc = ReaderDocument(content: content, rawData: data, fileHash: hash)
            if let previous = openedDocument, previous.securityScoped {
                previous.fileURL.stopAccessingSecurityScopedResource()
            }
            openedDocument = OpenedDocument(
                document: doc,
                fileURL: url,
                securityScoped: accessing
            )
            BookmarkStore.shared.saveURLBookmark(for: url, fileHash: hash)
            BookmarkStore.shared.updatePathHint(for: hash, url: url)
            CoverThumbnailCache.shared.generateIfNeeded(for: content, fileHash: hash)
            Task { await FileProviderPrimer.captureFileProviderRef(url: url, fileHash: hash) }
            browserLog.info("Document opened successfully: \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            browserLog.error("Failed to open: \(error.localizedDescription, privacy: .public)")
            if accessing { url.stopAccessingSecurityScopedResource() }
            if showError && activeOpenRequestID == requestID && !(error is CancellationError) {
                presentOpenError(error)
            }
            return error
        }
    }

    private func presentOpenError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private func closeDocument() {
        if let opened = openedDocument, opened.securityScoped {
            opened.fileURL.stopAccessingSecurityScopedResource()
        }
        openedDocument = nil
    }

    private func checkForPendingSharedFile() {
        guard openedDocument == nil else { return }
        let sharedDefaults = UserDefaults(suiteName: sharedGroupID)
        guard let pendingPath = sharedDefaults?.string(forKey: "pendingSharedFile") else { return }
        let fileURL = URL(fileURLWithPath: pendingPath)
        guard FileManager.default.fileExists(atPath: pendingPath) else {
            clearPendingSharedFile()
            return
        }
        clearPendingSharedFile()
        beginOpeningDocument(at: fileURL)
    }

    private func clearPendingSharedFile() {
        let sharedDefaults = UserDefaults(suiteName: sharedGroupID)
        sharedDefaults?.removeObject(forKey: "pendingSharedFile")
    }
}

// MARK: - Settings

struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            ReadingSettingsView(fileHash: nil)
                .tabItem { Label("Reading", systemImage: "textformat.size") }
            NavigationStack {
                PerBookSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .tabItem { Label("Books", systemImage: "books.vertical") }
        }
    }
}

// MARK: - Recents Grid

/// Scrollable grid of tracked books with cover thumbnails, logo, and heading.
private struct RecentsGridSection: View {
    let books: [AutoSavedPosition]
    let onTap: (AutoSavedPosition) -> Void
    var onRemove: ((AutoSavedPosition) -> Void)?

    @State private var showHelp = false

    private let columns = [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Centered logo
                Image("LaunchBackground")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                // Section header — left-aligned, system style
                HStack(spacing: 6) {
                    Text("Recently Opened and Bookmarked")
                        .font(.title3.weight(.semibold))
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Recent Books")
                    .popover(isPresented: $showHelp) {
                        recentsHelpContent
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)

                // Book grid
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(books) { entry in
                        RecentBookCell(entry: entry) {
                            onTap(entry)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                onRemove?(entry)
                            } label: {
                                Label("Remove from List", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }

    private var recentsHelpContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About Recent Books")
                .font(.headline)
            Text("The first time you open a book on a new device you need to locate it in the file picker.")
                .fixedSize(horizontal: false, vertical: true)
            Text("After that, the app tries the saved provider location and asks you to locate the file again only if iOS cannot open it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }
}

/// A single book cell with a cached cover thumbnail.
private struct RecentBookCell: View {
    let entry: AutoSavedPosition
    let onTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var triedGenerate = false

    private var fileExtension: String {
        (entry.fileName as NSString).pathExtension.lowercased()
    }

    private var fallbackIcon: String {
        switch fileExtension {
        case "pdf": return "doc.fill"
        case "epub": return "book.fill"
        case "cbz", "cbr": return "photo.on.rectangle.fill"
        case "txt", "md": return "doc.plaintext.fill"
        default: return "doc.fill"
        }
    }

    private var fallbackColor: Color {
        switch fileExtension {
        case "pdf": return .red
        case "epub": return .blue
        case "cbz", "cbr": return .purple
        case "txt", "md": return .orange
        default: return .gray
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 110)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fallbackColor.opacity(0.12))
                            .frame(width: 80, height: 110)
                            .overlay {
                                Image(systemName: fallbackIcon)
                                    .font(.title2)
                                    .foregroundStyle(fallbackColor)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

                Text((entry.fileName as NSString).deletingPathExtension)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: entry.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let cache = CoverThumbnailCache.shared

        // 1. On-disk cache (includes covers synced from iCloud KV store)
        if let cached = cache.cachedPath(for: entry.id),
           let image = UIImage(contentsOfFile: cached.path) {
            thumbnail = image
            return
        }

        guard !triedGenerate else { return }
        triedGenerate = true

        // 2. Try local URL bookmark
        if let url = BookmarkStore.shared.resolveURL(for: entry.id) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if await generateCover(from: url, cache: cache) { return }
        }

        // For thumbnails, we don't use revealDocument (it changes browser UI).
        // The iCloud-synced small cover from the other device should suffice.
    }

    private func generateCover(from url: URL, cache: CoverThumbnailCache) async -> Bool {
        let fileHash = entry.id
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return }
            cache.generateFromFileSync(at: url, data: data, fileHash: fileHash)
        }.value

        if !Task.isCancelled, let cached = cache.cachedPath(for: fileHash),
           let image = UIImage(contentsOfFile: cached.path) {
            thumbnail = image
            return true
        }
        return false
    }
}

// MARK: - Locate File Picker

/// A document picker presented when the user taps a recents item that hasn't been
/// opened on this device yet. Pre-navigates to the file's parent directory via
/// `directoryURL` so the user just needs to tap the file.
private struct LocateFilePickerView: UIViewControllerRepresentable {
    let directoryURL: URL?
    let fileName: String?
    let onOpen: (URL) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: ReaderDocument.readableContentTypes,
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        if let directoryURL {
            picker.directoryURL = directoryURL
        }

        let nav = UINavigationController(rootViewController: picker)

        // Add a header explaining what to do
        if let fileName {
            let label = UILabel()
            label.text = "Select \"\(fileName)\""
            label.font = .preferredFont(forTextStyle: .headline)
            label.textAlignment = .center
            picker.navigationItem.titleView = label
        }

        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onOpen: (URL) -> Void

        init(onOpen: @escaping (URL) -> Void) {
            self.onOpen = onOpen
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onOpen(url)
        }
    }
}

#endif
