import Foundation
import os

/// Persists reading positions for documents, synced via iCloud key-value store.
/// Supports up to 12 bookmarks per book, plus auto-saved reading positions.
///
/// Auto-save system:
/// - 60 books with bookmarks or custom settings track position and are never auto-evicted.
/// - 6 most recent books automatically track their reading position (rolling stack).
@Observable @MainActor
final class BookmarkStore {
    private static let logger = Logger(subsystem: "com.palefire.raedad", category: "BookmarkStore")
    static let shared = BookmarkStore()

    private(set) var entries: [BookmarkEntry] = []
    private(set) var autoSavedPositions: [AutoSavedPosition] = []

    private static let iCloudKey = "raedad.bookmarks"
    private static let autoSaveKey = "raedad.autoSavedPositions"
    private static let urlBookmarksKey = "raedad.urlBookmarks"
    private static let maxBookmarksPerBook = 12
    static let maxRecentBooks = 12
    static let maxPinnedBooks = 60
    private let cloud = NSUbiquitousKeyValueStore.default
    /// Device-local security-scoped URL bookmarks keyed by fileHash.
    /// These allow reopening files from the Recents list without re-picking.
    private var urlBookmarks: [String: Data] = [:]

    private static let bookmarkMigrationKey = "raedad.urlBookmarksMigrated_v2"

    private init() {
        self.entries = Self.loadFromCloud()
        self.autoSavedPositions = Self.loadAutoSaved()
        self.urlBookmarks = Self.loadURLBookmarks()

        // One-time migration: clear bookmarks saved with .minimalBookmark (broken security scope)
        if !UserDefaults.standard.bool(forKey: Self.bookmarkMigrationKey) {
            if !urlBookmarks.isEmpty {
                Self.logger.info("Migration: clearing \(self.urlBookmarks.count) old URL bookmarks (may have been .minimalBookmark)")
                urlBookmarks.removeAll()
                persistURLBookmarks()
            }
            UserDefaults.standard.set(true, forKey: Self.bookmarkMigrationKey)
        }

        Self.logger.info("BookmarkStore init: \(self.autoSavedPositions.count) tracked books, \(self.urlBookmarks.count) URL bookmarks")

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.entries = Self.loadFromCloud()
                self?.autoSavedPositions = Self.loadAutoSaved()
            }
        }
        cloud.synchronize()
    }

    // MARK: - Public API

    /// All bookmarks for a specific book, sorted by creation date (newest first).
    func bookmarks(for fileHash: String) -> [BookmarkEntry] {
        entries.filter { $0.fileHash == fileHash }.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Add a bookmark (up to 12 per book). Returns the new entry, or nil if at limit.
    @discardableResult
    func addBookmark(_ position: ReadingPosition, for fileURL: URL, data: Data, tocLabel: String? = nil) -> BookmarkEntry? {
        let hash = FileHasher.hash(data: data)
        guard bookmarkCount(for: hash) < Self.maxBookmarksPerBook else { return nil }

        let entry = BookmarkEntry(
            fileHash: hash,
            fileName: fileURL.lastPathComponent,
            position: position,
            lastOpened: Date(),
            tocLabel: tocLabel
        )
        entries.append(entry)
        persist()
        return entry
    }

    /// Remove a specific bookmark by its unique ID.
    func removeBookmark(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Check if a specific position is bookmarked.
    func isPositionBookmarked(fileHash: String, position: ReadingPosition) -> Bool {
        bookmarkAt(fileHash: fileHash, position: position) != nil
    }

    /// Find bookmark entry at a given position.
    func bookmarkAt(fileHash: String, position: ReadingPosition) -> BookmarkEntry? {
        entries.first { $0.fileHash == fileHash && positionsMatch($0.position, position) }
    }

    /// Whether any bookmarks exist for a book.
    func hasBookmarks(for fileHash: String) -> Bool {
        entries.contains { $0.fileHash == fileHash }
    }

    /// Count of bookmarks for a book.
    func bookmarkCount(for fileHash: String) -> Int {
        entries.filter { $0.fileHash == fileHash }.count
    }

    func clearAll() {
        entries.removeAll()
        persist()
    }

    func clearAllAutoSaved() {
        autoSavedPositions.removeAll()
        persistAutoSaved()
    }

    // MARK: - Auto-Save Positions

    /// Save or update the reading position for a book. Manages the recent stack and pinned limits.
    /// Returns an error message if the pinned limit is exceeded; nil on success.
    @discardableResult
    func savePosition(_ position: ReadingPosition, for fileURL: URL, data: Data, tocLabel: String? = nil) -> String? {
        let hash = FileHasher.hash(data: data)
        let fileName = fileURL.lastPathComponent
        let isPinned = hasBookmarks(for: hash) || ReadingPreferences.shared.hasOverride(for: hash)

        let pathHint = Self.extractRelativePathHint(from: fileURL)

        if let idx = autoSavedPositions.firstIndex(where: { $0.id == hash }) {
            // Update existing entry
            autoSavedPositions[idx].position = position
            autoSavedPositions[idx].lastOpened = Date()
            autoSavedPositions[idx].tocLabel = tocLabel
            autoSavedPositions[idx].pinned = isPinned
            if let pathHint { autoSavedPositions[idx].relativePathHint = pathHint }
            autoSavedPositions[idx].filePathString = fileURL.path
        } else {
            // New entry — check limits
            if isPinned {
                let pinnedCount = autoSavedPositions.filter(\.pinned).count
                if pinnedCount >= Self.maxPinnedBooks {
                    return "You have \(Self.maxPinnedBooks) books with custom settings or bookmarks. Please remove some before opening new books."
                }
            }
            let entry = AutoSavedPosition(
                id: hash, fileName: fileName, position: position,
                lastOpened: Date(), tocLabel: tocLabel, pinned: isPinned,
                relativePathHint: pathHint, filePathString: fileURL.path
            )
            autoSavedPositions.append(entry)
        }

        evictOldRecentBooks()
        persistAutoSaved()

        // Store a security-scoped URL bookmark so the file can be reopened from Recents
        saveURLBookmark(for: fileURL, fileHash: hash)

        // Generate cover thumbnail if not yet cached (runs in background)
        let url = fileURL
        let fileData = data
        let cache = CoverThumbnailCache.shared
        Task.detached(priority: .utility) {
            cache.generateFromFileSync(at: url, data: fileData, fileHash: hash)
        }

        return nil
    }

    /// Get the auto-saved position for a book.
    func savedPosition(for fileHash: String) -> AutoSavedPosition? {
        autoSavedPositions.first { $0.id == fileHash }
    }

    /// Remove an auto-saved position.
    func removeSavedPosition(for fileHash: String) {
        autoSavedPositions.removeAll { $0.id == fileHash }
        persistAutoSaved()
    }

    /// Refresh pinned status for a book (call after adding/removing bookmarks or settings).
    func refreshPinnedStatus(for fileHash: String) {
        guard let idx = autoSavedPositions.firstIndex(where: { $0.id == fileHash }) else { return }
        let isPinned = hasBookmarks(for: fileHash) || ReadingPreferences.shared.hasOverride(for: fileHash)
        if autoSavedPositions[idx].pinned != isPinned {
            autoSavedPositions[idx].pinned = isPinned
            persistAutoSaved()
        }
    }

    /// Recent (non-pinned) books, sorted newest first.
    var recentBooks: [AutoSavedPosition] {
        autoSavedPositions.filter { !$0.pinned }.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Pinned books (have bookmarks or custom settings), sorted newest first.
    var pinnedBooks: [AutoSavedPosition] {
        autoSavedPositions.filter(\.pinned).sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Evict oldest non-pinned books when the recent stack exceeds the limit.
    private func evictOldRecentBooks() {
        let recent = autoSavedPositions
            .enumerated()
            .filter { !$0.element.pinned }
            .sorted { $0.element.lastOpened > $1.element.lastOpened }

        if recent.count > Self.maxRecentBooks {
            let toRemove = recent.suffix(from: Self.maxRecentBooks).map(\.offset)
            for idx in toRemove.sorted().reversed() {
                autoSavedPositions.remove(at: idx)
            }
        }
    }

    private func persistAutoSaved() {
        do {
            let data = try JSONEncoder().encode(autoSavedPositions)
            cloud.set(data, forKey: Self.autoSaveKey)
            cloud.synchronize()
        } catch {
            Self.logger.error("Failed to encode auto-saved positions: \(error)")
        }
    }

    private static func loadAutoSaved() -> [AutoSavedPosition] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: autoSaveKey),
              let positions = try? JSONDecoder().decode([AutoSavedPosition].self, from: data) else {
            return []
        }
        return positions
    }

    // MARK: - Position Matching

    private func positionsMatch(_ a: ReadingPosition, _ b: ReadingPosition) -> Bool {
        switch (a, b) {
        case (.epubCFI(let cfiA, _), .epubCFI(let cfiB, _)):
            return cfiA == cfiB
        case (.pdfPage(let pageA), .pdfPage(let pageB)):
            return pageA == pageB
        case (.comicPage(let pageA), .comicPage(let pageB)):
            return pageA == pageB
        case (.textOffset(let offA), .textOffset(let offB)):
            return offA == offB
        case (.epubSpine(let idxA, _), .epubSpine(let idxB, _)):
            return idxA == idxB
        default:
            return false
        }
    }

    // MARK: - Path Hint

    /// Update the path hints for an existing entry (called from openDocument
    /// which may run before savePosition).
    func updatePathHint(for fileHash: String, url: URL) {
        guard let idx = autoSavedPositions.firstIndex(where: { $0.id == fileHash }) else { return }
        var changed = false
        if autoSavedPositions[idx].relativePathHint == nil,
           let hint = Self.extractRelativePathHint(from: url) {
            autoSavedPositions[idx].relativePathHint = hint
            changed = true
        }
        if autoSavedPositions[idx].filePathString != url.path {
            autoSavedPositions[idx].filePathString = url.path
            changed = true
        }
        if changed { persistAutoSaved() }
    }

    // MARK: - Path Hint Extraction

    /// Extract a cloud-provider-relative path from a file URL for cross-device matching.
    /// iCloud Drive: ".../Mobile Documents/com~apple~CloudDocs/Books/file.pdf" → "com~apple~CloudDocs/Books/file.pdf"
    /// Third-party providers: ".../File Provider Storage/ProviderID/path/file.pdf" → "ProviderID/path/file.pdf"
    private static func extractRelativePathHint(from url: URL) -> String? {
        let path = url.path
        // iCloud Drive: everything after "Mobile Documents/"
        if let range = path.range(of: "Mobile Documents/") {
            return String(path[range.upperBound...])
        }
        // File Provider Storage: everything after "File Provider Storage/"
        if let range = path.range(of: "File Provider Storage/") {
            return String(path[range.upperBound...])
        }
        return nil
    }

    // MARK: - Persistence (iCloud key-value store)

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            cloud.set(data, forKey: Self.iCloudKey)
            cloud.synchronize()
        } catch {
            Self.logger.error("Failed to encode bookmarks: \(error)")
        }
    }

    private static func loadFromCloud() -> [BookmarkEntry] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
              let entries = try? JSONDecoder().decode([BookmarkEntry].self, from: data) else {
            return []
        }
        return entries
    }

    // MARK: - URL Bookmark Storage (device-local)

    /// Save a security-scoped URL bookmark so the file can be reopened from Recents.
    func saveURLBookmark(for fileURL: URL, fileHash: String) {
        do {
            #if os(iOS)
            let data = try fileURL.bookmarkData(includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            #else
            let data = try fileURL.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            #endif
            urlBookmarks[fileHash] = data
            persistURLBookmarks()
            Self.logger.info("Saved URL bookmark for \(fileURL.lastPathComponent, privacy: .public) (\(data.count) bytes)")

            // Verify immediately
            var stale = false
            #if os(iOS)
            let resolved = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            #else
            let resolved = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            Self.logger.info("Bookmark verified: \(resolved.lastPathComponent, privacy: .public), stale=\(stale)")
        } catch {
            Self.logger.error("FAILED to save/verify URL bookmark for \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a URL bookmark is stored for this fileHash (lightweight, no resolution).
    func hasURLBookmark(for fileHash: String) -> Bool {
        urlBookmarks[fileHash] != nil
    }

    /// How many URL bookmarks are currently stored.
    var urlBookmarkCount: Int { urlBookmarks.count }

    /// Resolve a stored URL bookmark back to a file URL.
    /// Returns nil if no bookmark is stored or resolution fails.
    /// Caller is responsible for calling `startAccessingSecurityScopedResource()`.
    func resolveURL(for fileHash: String) -> URL? {
        guard let bookmarkData = urlBookmarks[fileHash] else {
            Self.logger.warning("No URL bookmark stored for hash \(fileHash.prefix(8), privacy: .public)")
            return nil
        }
        do {
            var isStale = false
            #if os(iOS)
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              bookmarkDataIsStale: &isStale)
            #else
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            #endif
            if isStale {
                Self.logger.info("Bookmark stale for \(url.lastPathComponent, privacy: .public), re-saving")
                saveURLBookmark(for: url, fileHash: fileHash)
            }
            return url
        } catch {
            Self.logger.error("FAILED to resolve URL bookmark for hash \(fileHash.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
            urlBookmarks.removeValue(forKey: fileHash)
            persistURLBookmarks()
            return nil
        }
    }

    /// Clear all stored URL bookmarks (used for migration from broken bookmark formats).
    func clearAllURLBookmarks() {
        urlBookmarks.removeAll()
        persistURLBookmarks()
        Self.logger.info("Cleared all URL bookmarks")
    }

    private func persistURLBookmarks() {
        UserDefaults.standard.set(urlBookmarks, forKey: Self.urlBookmarksKey)
    }

    private static func loadURLBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: urlBookmarksKey) as? [String: Data] ?? [:]
    }
}
