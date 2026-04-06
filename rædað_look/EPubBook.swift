import Foundation

/// Represents a fully parsed ePub document ready for rendering.
struct EPubBook: Sendable {
    let extractionDirectory: URL
    let metadata: Metadata
    let manifest: [String: ManifestItem]   // id → item
    let spine: [SpineItem]                 // ordered reading list
    let tableOfContents: [TOCEntry]
    let coverMetaID: String?               // from <meta name="cover" content="...">

    struct Metadata: Sendable {
        let title: String
        let author: String?
        let language: String?
    }

    struct ManifestItem: Sendable {
        let id: String
        let href: String        // path relative to extraction root
        let mediaType: String
        let properties: String?
    }

    struct SpineItem: Sendable {
        let idref: String       // references a manifest item id
        let linear: Bool
    }

    struct TOCEntry: Sendable, Identifiable {
        let id: String
        let title: String
        let href: String        // content file path + optional fragment
        let children: [TOCEntry]
    }

    /// Finds the cover image URL using ePub 3 properties, ePub 2 metadata, or heuristic.
    func coverImageURL() -> URL? {
        // Strategy 1: ePub 3 — manifest item with properties containing "cover-image"
        if let coverItem = manifest.values.first(where: {
            $0.properties?.contains("cover-image") == true
        }) {
            let url = extractionDirectory.appendingPathComponent(coverItem.href)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Strategy 2: ePub 2 — <meta name="cover" content="item-id">
        if let metaID = coverMetaID, let coverItem = manifest[metaID] {
            let url = extractionDirectory.appendingPathComponent(coverItem.href)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Strategy 3: heuristic — image manifest item with "cover" in id or href
        if let coverItem = manifest.values.first(where: {
            $0.mediaType.hasPrefix("image/") &&
            ($0.id.localizedCaseInsensitiveContains("cover") ||
             $0.href.localizedCaseInsensitiveContains("cover"))
        }) {
            let url = extractionDirectory.appendingPathComponent(coverItem.href)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    /// Resolves a spine index to an absolute file URL for loading in WKWebView.
    func fileURL(forSpineIndex index: Int) -> URL? {
        guard index >= 0, index < spine.count else { return nil }
        let spineItem = spine[index]
        guard let manifestItem = manifest[spineItem.idref] else { return nil }
        return extractionDirectory.appendingPathComponent(manifestItem.href)
    }

    /// Finds the spine index for a TOC entry's href.
    func spineIndex(for tocEntry: TOCEntry) -> Int? {
        // Strip fragment identifier from href for matching
        let basePath = tocEntry.href.components(separatedBy: "#").first ?? tocEntry.href

        for (index, spineItem) in spine.enumerated() {
            guard let manifestItem = manifest[spineItem.idref] else { continue }
            if manifestItem.href == basePath || manifestItem.href.hasSuffix(basePath) {
                return index
            }
        }
        return nil
    }

    /// Extracts the fragment identifier from a TOC entry's href (e.g., "chapter1.xhtml#section2" → "section2").
    func fragment(for tocEntry: TOCEntry) -> String? {
        let parts = tocEntry.href.components(separatedBy: "#")
        return parts.count > 1 ? parts[1] : nil
    }
}
