import SwiftUI

/// A picker dialog showing bookmarks for the current book, allowing the reader to jump to one.
struct BookmarkPickerView: View {
    let fileHash: String
    let onSelect: (ReadingPosition) -> Void

    @Environment(\.dismiss) private var dismiss
    private let store = BookmarkStore.shared

    private var bookmarks: [BookmarkEntry] {
        store.bookmarks(for: fileHash)
    }

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark.slash",
                    description: Text("Use the bookmark button to save positions in this book.")
                )
            } else {
                List(bookmarks) { entry in
                    Button {
                        onSelect(entry.position)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.position.displayString)
                                if let tocLabel = entry.tocLabel {
                                    Text(tocLabel)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text("Saved \(entry.lastOpened, style: .relative) ago")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Bookmarks")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            #endif
        }
    }
}
