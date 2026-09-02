import SwiftUI

/// Displays a navigable tree of ePub table of contents entries.
struct TableOfContentsView: View {
    let entries: [EPubBook.TOCEntry]
    var currentTOCLabel: String? = nil
    var bookmarkTOCLabels: Set<String> = []
    let onSelect: (EPubBook.TOCEntry) -> Void

    var body: some View {
        List {
            ForEach(entries) { entry in
                TOCRowView(
                    entry: entry,
                    currentTOCLabel: currentTOCLabel,
                    bookmarkTOCLabels: bookmarkTOCLabels,
                    onSelect: onSelect
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Contents")
    }
}

/// A single row in the TOC tree, supporting nested children via DisclosureGroup.
private struct TOCRowView: View {
    let entry: EPubBook.TOCEntry
    let currentTOCLabel: String?
    let bookmarkTOCLabels: Set<String>
    let onSelect: (EPubBook.TOCEntry) -> Void

    private var isCurrent: Bool {
        currentTOCLabel == entry.title
    }

    private var isBookmarked: Bool {
        bookmarkTOCLabels.contains(entry.title)
    }

    var body: some View {
        if entry.children.isEmpty {
            Button {
                onSelect(entry)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
        } else {
            DisclosureGroup {
                ForEach(entry.children) { child in
                    TOCRowView(
                        entry: child,
                        currentTOCLabel: currentTOCLabel,
                        bookmarkTOCLabels: bookmarkTOCLabels,
                        onSelect: onSelect
                    )
                }
            } label: {
                Button {
                    onSelect(entry)
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        HStack {
            Text(entry.title)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
