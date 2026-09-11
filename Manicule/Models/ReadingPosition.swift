import Foundation

/// Represents a saved reading position within a document.
enum ReadingPosition: Codable, Sendable, Equatable {
    case pdfPage(Int)
    case epubSpine(index: Int, scrollFraction: Double)
    case epubCFI(String, fraction: Double)
    case textOffset(Int) // Legacy fraction multiplied by 1000.
    case textAnchor(TextAnchor, fraction: Double)
    case comicPage(Int)

    var displayString: String {
        switch self {
        case .pdfPage(let page):
            return "Page \(page == Int.max ? Int.max : max(0, page) + 1)"
        case .epubSpine(let index, _):
            return "Chapter \(index == Int.max ? Int.max : max(0, index) + 1)"
        case .epubCFI(_, let fraction):
            return "\(Int(Self.validFraction(fraction) * 100))%"
        case .textAnchor(let anchor, _):
            return "Line \(anchor.line + 1)"
        case .textOffset(let offset):
            return "Position \(offset)"
        case .comicPage(let page):
            return "Page \(page == Int.max ? Int.max : max(0, page) + 1)"
        }
    }

    private static func validFraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// Extracts a global fraction for approximate position restoration.
    var epubFraction: Double? {
        switch self {
        case .epubCFI(_, let fraction): return Self.validFraction(fraction)
        case .epubSpine(_, let fraction): return Self.validFraction(fraction)
        default: return nil
        }
    }
}

/// An automatically saved reading position for a book.
struct AutoSavedPosition: Codable, Identifiable, Sendable, Equatable {
    var id: String          // fileHash
    var fileName: String
    var position: ReadingPosition
    var lastOpened: Date
    var tocLabel: String?
    /// Whether this book is "pinned" (has manual bookmarks or custom settings).
    /// Pinned books are never auto-evicted from the recent stack.
    var pinned: Bool = false
    /// Cloud-provider-relative path hint for cross-device file discovery.
    /// e.g. "com~apple~CloudDocs/Books/file.pdf" — syncs via iCloud KV.
    var relativePathHint: String?
    /// Full file system path, synced via iCloud for cross-device file resolution.
    /// On iOS, iCloud Drive paths are consistent across devices.
    var filePathString: String?
}

/// Typed representation of an ePub relocate event from foliate-js.
struct RelocateEvent {
    let fraction: Double?
    let cfi: String?
    let tocLabel: String?
    let atStart: Bool?
    let atEnd: Bool?
    let page: Int?
    let pages: Int?
    let sectionIndex: Int?
    let sectionCount: Int?

    init(from dict: [String: Any]) {
        fraction = dict["fraction"] as? Double
        cfi = dict["cfi"] as? String
        if let tocItem = dict["tocItem"] as? [String: Any] {
            tocLabel = tocItem["label"] as? String
        } else {
            tocLabel = nil
        }
        atStart = dict["atStart"] as? Bool
        atEnd = dict["atEnd"] as? Bool
        page = dict["page"] as? Int
        pages = dict["pages"] as? Int
        if let section = dict["section"] as? [String: Any] {
            sectionIndex = section["current"] as? Int
            sectionCount = section["total"] as? Int
        } else {
            sectionIndex = nil
            sectionCount = nil
        }
    }
}

/// A saved bookmark entry for a specific file.
struct BookmarkEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String          // Unique ID (UUID string)
    var fileHash: String    // SHA256 hash — groups bookmarks per book
    var fileName: String    // Display name
    var position: ReadingPosition
    var lastOpened: Date
    var tocLabel: String?   // ePub: TOC entry label at bookmark position

    /// Migration: old entries have id = fileHash and no fileHash field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decode(String.self, forKey: .id)
        let rawHash = try container.decodeIfPresent(String.self, forKey: .fileHash)
        if let hash = rawHash {
            self.id = rawId
            self.fileHash = hash
        } else {
            // Legacy entry: id was the file hash
            self.id = "legacy-" + rawId
            self.fileHash = rawId
        }
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.position = try container.decode(ReadingPosition.self, forKey: .position)
        self.lastOpened = try container.decode(Date.self, forKey: .lastOpened)
        self.tocLabel = try container.decodeIfPresent(String.self, forKey: .tocLabel)
    }

    init(id: String = UUID().uuidString, fileHash: String, fileName: String, position: ReadingPosition, lastOpened: Date, tocLabel: String? = nil) {
        self.id = id
        self.fileHash = fileHash
        self.fileName = fileName
        self.position = position
        self.lastOpened = lastOpened
        self.tocLabel = tocLabel
    }
}

/// A source block and a short passage within it, independent of screen layout.
/// UTF-16 offset disambiguates repeated passages within the same block.
struct TextAnchor: Codable, Sendable, Equatable {
    let line: Int
    let offset: Int
    let quote: String

    private enum CodingKeys: String, CodingKey { case line, offset, quote }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(line: try values.decode(Int.self, forKey: .line),
                  offset: try values.decode(Int.self, forKey: .offset),
                  quote: try values.decode(String.self, forKey: .quote))
    }

    init(line: Int, offset: Int = 0, quote: String = "") {
        self.line = min(max(0, line), Int.max - 1)
        self.offset = max(0, offset)
        self.quote = String(quote.prefix(80))
    }
}

extension ReadingPosition {
    var textFraction: Double? {
        switch self {
        case .textOffset(let offset): return min(1, max(0, Double(offset) / 1000))
        case .textAnchor(_, let fraction): return fraction.isFinite ? min(1, max(0, fraction)) : 0
        default: return nil
        }
    }
    var textAnchor: TextAnchor? {
        if case .textAnchor(let anchor, _) = self { return anchor }
        return nil
    }
}
