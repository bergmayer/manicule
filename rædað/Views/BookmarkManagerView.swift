import SwiftUI

/// Displays all saved reading positions (manual bookmarks and auto-saved) and allows management.
struct BookmarkManagerView: View {
    private let store = BookmarkStore.shared
    @State private var showClearConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.entries.isEmpty && store.autoSavedPositions.isEmpty {
                ContentUnavailableView(
                    "No Saved Positions",
                    systemImage: "bookmark.slash",
                    description: Text("Reading positions are saved automatically for recent books. Use the bookmark button to save specific positions.")
                )
            } else {
                List {
                    if !store.autoSavedPositions.isEmpty {
                        Section("Reading Positions") {
                            ForEach(store.autoSavedPositions.sorted(by: { $0.lastOpened > $1.lastOpened })) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.fileName)
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            Text(entry.position.displayString)
                                                .font(.subheadline)
                                            if let tocLabel = entry.tocLabel {
                                                Text("· \(tocLabel)")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                        Text(entry.lastOpened, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if entry.pinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete(perform: deleteAutoSaved)
                        }
                    }

                    if !store.entries.isEmpty {
                        ForEach(groupedKeys, id: \.self) { hash in
                            let group = grouped[hash]!
                            Section("Bookmarks: \(group.first!.fileName)") {
                                ForEach(group.sorted(by: { $0.lastOpened > $1.lastOpened })) { entry in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 4) {
                                                Text(entry.position.displayString)
                                                    .font(.subheadline)
                                                if let tocLabel = entry.tocLabel {
                                                    Text("· \(tocLabel)")
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Text("Saved \(entry.lastOpened, style: .relative) ago")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            store.removeBookmark(id: entry.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved Positions")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            #endif
            ToolbarItem(placement: .destructiveAction) {
                if !store.entries.isEmpty || !store.autoSavedPositions.isEmpty {
                    Button("Clear All", role: .destructive) {
                        showClearConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear All Saved Positions?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                store.clearAll()
                store.clearAllAutoSaved()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all saved reading positions and bookmarks. This action cannot be undone.")
        }
    }

    private var grouped: [String: [BookmarkEntry]] {
        Dictionary(grouping: store.entries) { $0.fileHash }
    }

    private var groupedKeys: [String] {
        let g = grouped
        return g.keys.sorted { a, b in
            let aDate = g[a]!.map(\.lastOpened).max() ?? .distantPast
            let bDate = g[b]!.map(\.lastOpened).max() ?? .distantPast
            return aDate > bDate
        }
    }

    private func deleteAutoSaved(at offsets: IndexSet) {
        let sorted = store.autoSavedPositions.sorted(by: { $0.lastOpened > $1.lastOpened })
        for index in offsets {
            store.removeSavedPosition(for: sorted[index].id)
        }
    }
}
