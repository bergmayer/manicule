import SwiftUI

/// Shared search bar UI used by all reader types.
/// Displays a text field, result count, and prev/next/dismiss buttons.
struct SearchBarView: View {
    @Binding var query: String
    @Binding var isSearching: Bool
    let resultCount: Int
    let currentResult: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void
    /// Minimum query length before the search backend runs. Used to display
    /// a hint instead of "No results" while the user is still typing.
    var minQueryLength: Int = 0

    @FocusState private var isFocused: Bool

    private var trimmedQueryLength: Int {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var isWaitingForLongerQuery: Bool {
        minQueryLength > 0 && trimmedQueryLength > 0 && trimmedQueryLength < minQueryLength
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search...", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onNext() }
                #if os(macOS)
                .frame(minWidth: 120)
                #endif

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if resultCount > 0 {
                Text("\(currentResult)/\(resultCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if isWaitingForLongerQuery {
                Text("Keep typing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !query.isEmpty && !isSearching {
                Text("No results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .disabled(resultCount == 0)
            .buttonStyle(.borderless)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .disabled(resultCount == 0)
            .buttonStyle(.borderless)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
