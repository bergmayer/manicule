import SwiftUI

/// Combined management view for per-book settings overrides, bookmarks, and auto-saved positions.
struct PerBookSettingsView: View {
    private let prefs = ReadingPreferences.shared
    private let bookmarkStore = BookmarkStore.shared
    @State private var showClearAllConfirmation = false

    var body: some View {
        List {
            Section("Usage") {
                LabeledContent("Custom settings and saved bookmarks", value: "\(bookmarkStore.pinnedBooks.count)/\(BookmarkStore.maxPinnedBooks)")
                LabeledContent("Recent (position only)", value: "\(bookmarkStore.recentBooks.count)/\(BookmarkStore.maxRecentBooks)")
            }

            if !bookmarkStore.pinnedBooks.isEmpty {
                Section("Books with Bookmarks or Settings") {
                    ForEach(bookmarkStore.pinnedBooks) { entry in
                        pinnedRow(entry)
                    }
                }
            }

            if !bookmarkStore.recentBooks.isEmpty {
                Section("Recent") {
                    ForEach(bookmarkStore.recentBooks) { entry in
                        recentRow(entry)
                    }
                }
            }

            if !bookmarkStore.autoSavedPositions.isEmpty || !bookmarkStore.entries.isEmpty
                || !prefs.perBookOverrides.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Books")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Clear All?", isPresented: $showClearAllConfirmation, titleVisibility: .visible) {
            Button("Clear All Book Data", role: .destructive) {
                bookmarkStore.clearAll()
                bookmarkStore.clearAllAutoSaved()
                bookmarkStore.clearAllURLBookmarks()
                bookmarkStore.clearAllFileProviderRefs()
                prefs.clearAllOverrides()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all saved positions, bookmarks, custom book settings, and the Recently Opened list. This cannot be undone.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func recentRow(_ entry: AutoSavedPosition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).lineLimit(1)
                if let path = displayPath(for: entry) {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(entry.position.displayString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let tocLabel = entry.tocLabel {
                        Text("· \(tocLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(entry.lastOpened, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) {
                bookmarkStore.removeSavedPosition(for: entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func pinnedRow(_ entry: AutoSavedPosition) -> some View {
        let hash = entry.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).lineLimit(1)
                if let path = displayPath(for: entry) {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(entry.position.displayString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let tocLabel = entry.tocLabel {
                        Text("· \(tocLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if bookmarkStore.hasBookmarks(for: hash) {
                        Label("\(bookmarkStore.bookmarkCount(for: hash))", systemImage: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if prefs.hasOverride(for: hash) {
                        Label("Custom", systemImage: "textformat.size")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.lastOpened, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) {
                // Remove everything for this book
                for bookmark in bookmarkStore.bookmarks(for: hash) {
                    bookmarkStore.removeBookmark(id: bookmark.id)
                }
                if prefs.hasOverride(for: hash) {
                    prefs.removeOverride(for: hash)
                }
                bookmarkStore.removeSavedPosition(for: hash)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    /// Choose the most useful path representation for display.
    ///
    /// Preference order:
    ///   1. `relativePathHint` — cloud-provider-relative ("Books/MyBook.epub").
    ///      Stable across devices and the cleanest form to read.
    ///   2. `filePathString` — full path. We collapse the home directory to
    ///      `~`, and trim provider-storage prefixes so users see the part
    ///      they recognize rather than `/private/var/mobile/Containers/…`.
    ///   3. Nothing if neither is stored (very old entries pre-path-tracking).
    private func displayPath(for entry: AutoSavedPosition) -> String? {
        if let hint = entry.relativePathHint, !hint.isEmpty {
            return cleanedPath(hint)
        }
        if let full = entry.filePathString, !full.isEmpty {
            return cleanedPath(abbreviate(fullPath: full))
        }
        return nil
    }

    private func abbreviate(fullPath: String) -> String {
        let home = NSHomeDirectory()
        if !home.isEmpty, fullPath.hasPrefix(home) {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }

    /// Drop the trailing file name (it's already shown as the row title) and
    /// strip a leading slash so the directory reads cleanly. Returns nil-ish
    /// (empty) handling deferred to the caller via `isEmpty` check above.
    private func cleanedPath(_ path: String) -> String {
        var p = path
        if let slash = p.lastIndex(of: "/") {
            p = String(p[..<slash])
        } else {
            return ""
        }
        if p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
