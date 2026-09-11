#if os(iOS)
import Foundation
import FileProvider
import os.log

private nonisolated let primerLog = Logger(subsystem: "com.palefire.manicule", category: "FileProviderPrimer")

/// FileProvider helpers for capturing stable identifiers on open and
/// re-vending URLs on later reopens.
///
/// Background: plain `URL.bookmarkData()` round-trips don't reliably persist
/// access for third-party File Provider extensions (Nextcloud, Dropbox, etc.)
/// across launches. Capturing the `(domain, item)` pair and asking the
/// provider to re-vend a URL at open time is the only durable handle we get.
enum FileProviderPrimer {
    enum ResolveBudget {
        case probe
        case prewarm

        nonisolated var delaysMillis: [UInt64] {
            switch self {
            case .probe:
                return [0]
            case .prewarm:
                return [0, 400, 1000, 1700, 1900]
            }
        }
    }

    /// Called once at app start. Wakes registered FileProvider extensions and
    /// fires per-book resolves in the background for the top-N most-recently-
    /// opened books that have a captured ref. Cross-device coverage falls
    /// out for free since `autoSavedPositions` is iCloud-synced.
    @MainActor
    static func startPrewarm() async {
        let entries = BookmarkStore.shared.autoSavedPositions
            .sorted { $0.lastOpened > $1.lastOpened }
            .prefix(12)
        let candidates: [(String, FileProviderRef)] = entries.compactMap { entry in
            BookmarkStore.shared.fileProviderRef(for: entry.id).map { (entry.fileName, $0) }
        }

        // Wake registered providers even if we have no candidates — a user
        // about to pick a new file via the locator benefits from a warmer
        // extension.
        await wakeProviders()

        guard !candidates.isEmpty else { return }
        primerLog.info("Pre-warm: nudging FileProvider for \(candidates.count) recent books")

        await withTaskGroup(of: Void.self) { group in
            for (name, ref) in candidates {
                group.addTask(priority: .background) {
                    guard !Task.isCancelled else { return }
                    if (await resolveFileProviderURL(ref, budget: .prewarm)) != nil {
                        primerLog.info("Pre-warm: \(name, privacy: .public) primed")
                    }
                }
            }
        }
    }

    /// Nudge the system to load registered File Provider domains. Useful even
    /// when we don't yet have a captured item identifier for an older recent
    /// entry, because provider registration often precedes saved-path access.
    nonisolated static func wakeProviders() async {
        _ = try? await NSFileProviderManager.domains()
    }

    /// Ask the FileProvider system for stable identifiers for this URL and
    /// remember them. Silently no-ops for files not vended by a file provider
    /// (sandbox imports, Inbox files, etc.).
    nonisolated static func captureFileProviderRef(url: URL, fileHash: String) async {
        primerLog.info("Attempting FP capture for \(url.lastPathComponent, privacy: .public)")
        do {
            let (itemID, domainID) = try await NSFileProviderManager.identifierForUserVisibleFile(at: url)
            try Task.checkCancellation()
            await MainActor.run {
                guard !Task.isCancelled else { return }
                BookmarkStore.shared.saveFileProviderRef(
                    domain: domainID.rawValue,
                    item: itemID.rawValue,
                    fileHash: fileHash
                )
            }
        } catch {
            // Warning-level so this shows up in default Console.app filtering.
            primerLog.warning("FP capture FAILED for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask the relevant FileProvider extension to vend a fresh URL for the
    /// previously-captured (domain, item) reference. Returns nil if the
    /// provider can't fulfill it.
    ///
    /// Uses the requested budget: recents use a single probe, while launch-time
    /// prewarming can retry in the background without putting UI in front of
    /// the user.
    nonisolated static func resolveFileProviderURL(_ ref: FileProviderRef, budget: ResolveBudget = .probe) async -> URL? {
        let domainID = NSFileProviderDomainIdentifier(ref.domain)
        let itemID = NSFileProviderItemIdentifier(ref.item)
        for (attempt, delay) in budget.delaysMillis.enumerated() {
            do {
                try Task.checkCancellation()
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                let domains = try await NSFileProviderManager.domains()
                guard let domain = domains.first(where: { $0.identifier == domainID }),
                      let manager = NSFileProviderManager(for: domain) else {
                    primerLog.info("FP attempt \(attempt + 1): domain \(ref.domain, privacy: .public) not present yet")
                    continue
                }
                let url = try await manager.getUserVisibleURL(for: itemID)
                try Task.checkCancellation()
                primerLog.info("FP attempt \(attempt + 1): resolved \(url.lastPathComponent, privacy: .public)")
                return url
            } catch is CancellationError {
                return nil
            } catch {
                primerLog.info("FP attempt \(attempt + 1) failed for \(ref.domain, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}
#endif
