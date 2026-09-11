import Foundation

/// Owns a temporary extraction directory and removes it when the parsed
/// document using it is released.
final class TemporaryDirectoryLease: Sendable {
    nonisolated let url: URL

    nonisolated init(url: URL) {
        self.url = url
    }

    nonisolated static func create(prefix: String) throws -> TemporaryDirectoryLease {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TemporaryDirectoryLease(url: url)
    }

    /// Publish a file only after a successful atomic write. On failure the
    /// local lease removes the partial workspace automatically.
    nonisolated static func writing(_ data: Data, filename: String) throws -> TemporaryDirectoryLease {
        let directory = try create(prefix: "manicule-render")
        try data.write(to: directory.url.appendingPathComponent(filename), options: .atomic)
        return directory
    }

    nonisolated deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
