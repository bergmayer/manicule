import Foundation

/// Owns a temporary extraction directory for the lifetime of a Quick Look
/// parsed document.
final class TemporaryDirectoryLease: @unchecked Sendable {
    let url: URL

    nonisolated init(url: URL) {
        self.url = url
    }

    nonisolated deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
