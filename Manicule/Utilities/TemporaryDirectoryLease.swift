import Foundation

/// Owns a temporary extraction directory and removes it when the parsed
/// document using it is released.
final class TemporaryDirectoryLease: @unchecked Sendable {
    let url: URL

    nonisolated init(url: URL) {
        self.url = url
    }

    nonisolated deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
