import Foundation
import CryptoKit

/// Generates a stable identifier for a file based on its content.
/// The caller already has the document in memory, so hashing the complete data
/// avoids treating different books with identical headers as the same file.
enum FileHasher: Sendable {
    nonisolated static func hash(data: Data) -> String {
        digestString(for: data)
    }

    /// Identifier used by releases that hashed only the first 64 KiB. Kept
    /// solely to migrate existing bookmarks, positions, settings, and covers.
    nonisolated static func legacyHash(data: Data, prefixBytes: Int = 65_536) -> String {
        digestString(for: Data(data.prefix(prefixBytes)))
    }

    private nonisolated static func digestString(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
