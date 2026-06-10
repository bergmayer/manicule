import Foundation
import CryptoKit

/// Generates a stable identifier for a file based on its content.
/// Uses SHA256 of the first 64KB to avoid reading entire large files.
enum FileHasher: Sendable {
    nonisolated static func hash(data: Data, prefixBytes: Int = 65_536) -> String {
        let prefix = data.prefix(prefixBytes)
        let digest = SHA256.hash(data: prefix)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
