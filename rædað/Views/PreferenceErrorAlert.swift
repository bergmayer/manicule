import SwiftUI

private struct PreferenceErrorAlertModifier: ViewModifier {
    private let preferences = ReadingPreferences.shared
    private let bookmarks = BookmarkStore.shared

    func body(content: Content) -> some View {
        content.alert(
            "Book Data Not Saved",
            isPresented: Binding(
                get: { preferences.lastError != nil || bookmarks.lastError != nil },
                set: {
                    if !$0 {
                        preferences.clearLastError()
                        bookmarks.clearLastError()
                    }
                }
            )
        ) {
            Button("OK") {
                preferences.clearLastError()
                bookmarks.clearLastError()
            }
        } message: {
            Text(preferences.lastError ?? bookmarks.lastError ?? "The change could not be saved.")
        }
    }
}

extension View {
    func preferenceErrorAlert() -> some View {
        modifier(PreferenceErrorAlertModifier())
    }
}
