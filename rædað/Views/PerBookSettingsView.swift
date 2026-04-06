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

            if !bookmarkStore.autoSavedPositions.isEmpty || !bookmarkStore.entries.isEmpty {
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
            Button("Clear All Books and Bookmarks", role: .destructive) {
                bookmarkStore.clearAll()
                bookmarkStore.clearAllAutoSaved()
                bookmarkStore.clearAllURLBookmarks()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all saved positions, bookmarks, and the Recently Opened list. This cannot be undone.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func recentRow(_ entry: AutoSavedPosition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).lineLimit(1)
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
}
