import SwiftUI

private struct PreferenceErrorAlertModifier: ViewModifier {
    private let preferences = ReadingPreferences.shared
    private let bookmarks = BookmarkStore.shared
    @State private var acknowledgedErrors: Set<String> = []

    // Autosave can encounter the same cloud failure on every page turn. Show
    // each message once per window, while retaining the stores' diagnostics.
    private var pendingError: String? {
        [preferences.lastError, bookmarks.lastError].compactMap { $0 }
            .first { !acknowledgedErrors.contains($0) }
    }

    func body(content: Content) -> some View {
        content.alert(
            "Reading Data",
            isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0, let error = pendingError { acknowledgedErrors.insert(error) } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(pendingError ?? "The change could not be saved.")
        }
    }
}

extension View {
    func preferenceErrorAlert() -> some View {
        modifier(PreferenceErrorAlertModifier())
    }
}
