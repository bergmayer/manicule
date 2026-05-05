import SwiftUI

/// Namespace for shared reader utility functions.
enum ReaderHelpers {

    // MARK: - Automatic Two-Up Resolution

    /// Resolves the auto two-up state from the current view size, used for
    /// Swift-side display (toolbar icon, margin selection). iPhone always
    /// returns false (landscape too narrow for two columns). Other devices
    /// return true when the area is wider than tall.
    static func defaultTwoUp(viewWidth: CGFloat, viewHeight: CGFloat) -> Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return false }
        #endif
        guard viewWidth > 0, viewHeight > 0 else {
            return defaultTwoUpForOrientation()
        }
        return viewWidth > viewHeight
    }

    /// Fallback used before the view size is known.
    static func defaultTwoUpForOrientation() -> Bool {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return false }
        let bounds = scene.screen.bounds
        return bounds.width > bounds.height && UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    // MARK: - Bridge twoUp resolution

    /// Resolves a `twoUpOverride` (nil = auto, true/false = explicit) into the
    /// value to send to the JS bridge. iPhone collapses auto to single page,
    /// since landscape is too narrow for a real two-column spread; on other
    /// devices nil flows through and the bridge auto-resolves from viewport
    /// orientation (and re-resolves on every resize).
    static func resolveTwoUpForBridge(_ override: Bool?) -> Bool? {
        if let override { return override }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return false }
        #endif
        return nil
    }

    /// Same as `resolveTwoUpForBridge` but as an Int? for ePub's column-count API:
    /// nil = auto (bridge resolves), 1 = force single, 2 = force two-up.
    static func resolveColumnCountForBridge(_ override: Bool?) -> Int? {
        switch resolveTwoUpForBridge(override) {
        case .some(true): return 2
        case .some(false): return 1
        case .none: return nil
        }
    }

    // MARK: - View Mode Icon

    /// Returns the SF Symbol name for the current view mode state.
    static func viewModeIcon(isPaginated: Bool, isTwoUp: Bool) -> String {
        if !isPaginated { return "scroll.fill" }
        if isTwoUp { return "rectangle.split.2x1.fill" }
        return "rectangle.fill"
    }

    // MARK: - Bookmark Helpers

    /// Toggles a bookmark at the given position for a file.
    static func toggleBookmark(
        store: BookmarkStore,
        fileURL: URL?,
        fileHash: String?,
        rawData: Data,
        position: ReadingPosition,
        tocLabel: String? = nil
    ) {
        guard let url = fileURL, let hash = fileHash else { return }
        if let existing = store.bookmarkAt(fileHash: hash, position: position) {
            store.removeBookmark(id: existing.id)
        } else {
            store.addBookmark(position, for: url, data: rawData, tocLabel: tocLabel)
        }
    }

    // MARK: - Page Label

    /// Formats a page label like "3 of 10" or "3–4 of 10" for two-up mode.
    static func pageLabel(current: Int, total: Int, twoUp: Bool) -> String {
        guard total > 0 else { return "" }
        if twoUp && current + 1 < total {
            return "\(current + 1)–\(current + 2) of \(total)"
        }
        return "\(current + 1) of \(total)"
    }

    // MARK: - Position Restoration

    /// Restores the most recent saved position for a page-based reader (PDF, comic).
    /// Returns the page index to restore to, or nil if no position was found.
    static func restorePagePosition(
        store: BookmarkStore,
        fileHash: String?,
        pageCount: Int,
        extract: (ReadingPosition) -> Int?
    ) -> Int? {
        guard let hash = fileHash else { return nil }
        // Auto-saved first
        if let autoSaved = store.savedPosition(for: hash),
           let page = extract(autoSaved.position),
           page < pageCount {
            return page
        }
        // Then manual bookmarks
        if let mostRecent = store.bookmarks(for: hash).first,
           let page = extract(mostRecent.position),
           page < pageCount {
            return page
        }
        return nil
    }
}
