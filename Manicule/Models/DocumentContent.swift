import Foundation
import UniformTypeIdentifiers
import os.log

private nonisolated let contentLog = Logger(subsystem: "com.palefire.manicule", category: "Content")

/// Custom UTTypes for comic book archives.
/// Using exportedAs: guarantees a valid UTType regardless of other apps' type
/// declarations or UTType cache state — UTType("...") returns nil if the
/// identifier isn't registered yet. These match UTExportedTypeDeclarations
/// in Info.plist where the types conform ONLY to public.data (not
/// public.archive or public.zip-archive) to prevent iOS's system archive
/// handler from hijacking Quick Look previews.
extension UTType {
    nonisolated static let cbzArchive = UTType(exportedAs: "com.palefire.manicule.cbz-archive")
    nonisolated static let cbrArchive = UTType(exportedAs: "com.palefire.manicule.cbr-archive")
}

/// The parsed content of an opened document, dispatched by file type.
enum DocumentContent: Sendable {
    case pdf(Data)
    case epub(EPubBook)
    case plainText(String)
    case markdown(String)
    case comic(ComicArchive)

    /// Parse document data into the appropriate content type.
    /// - Parameters:
    ///   - data: Raw file data
    ///   - contentType: UTType reported by the system (may be generic for SMB/remote files)
    ///   - filename: Optional filename for extension-based detection when contentType is generic
    nonisolated static func parse(data: Data, contentType: UTType, filename: String? = nil) throws -> DocumentContent {
        // Prefer the actual filename extension — it preserves .cbz/.cbr even when
        // the system assigns a generic type like public.zip-archive (preferredExtension = "zip").
        // Fall back to contentType's preferred extension if filename has no extension.
        let filenameExt = filename
            .flatMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let ext = filenameExt ?? contentType.preferredFilenameExtension?.lowercased()

        if contentType.conforms(to: .pdf) || ext == "pdf" {
            return .pdf(data)
        }
        if contentType.conforms(to: .epub) || ext == "epub" {
            let book = try EPubParser.parse(data: data)
            return .epub(book)
        }
        if contentType.conforms(to: .cbzArchive) || ext == "cbz" {
            contentLog.info("Parsing CBZ: \(data.count) bytes")
            do {
                let archive = try ComicArchiveParser.parse(data: data)
                contentLog.info("CBZ parsed: \(archive.pageCount) pages")
                return .comic(archive)
            } catch {
                contentLog.error("CBZ parse failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        if contentType.conforms(to: .cbrArchive) || ext == "cbr" {
            contentLog.info("Parsing CBR: \(data.count) bytes")
            do {
                let archive = try ComicArchiveParser.parseRAR(data: data)
                contentLog.info("CBR parsed: \(archive.pageCount) pages")
                return .comic(archive)
            } catch {
                contentLog.error("CBR parse failed: \(error.localizedDescription, privacy: .public)")
                throw DocumentError.parsingFailed("CBR: \(error.localizedDescription)")
            }
        }
        // Markdown before plainText since markdown conforms to plainText.
        // Use UTType("...") instead of UTType(importedAs:) — the latter can
        // return wrong types when another app has conflicting UTI declarations.
        let markdownType = UTType("net.daringfireball.markdown")
        let maniculeMarkdownType = UTType("com.palefire.manicule.markdown")
        if markdownType.map({ contentType.conforms(to: $0) }) == true
            || maniculeMarkdownType.map({ contentType.conforms(to: $0) }) == true
            || contentType.identifier == "net.daringfireball.markdown"
            || contentType.identifier == "com.palefire.manicule.markdown"
            || ext == "md" || ext == "markdown" {
            return .markdown(try decodeText(data))
        }
        if contentType.conforms(to: .plainText) || ext == "txt" {
            return .plainText(try decodeText(data))
        }

        // Last resort: detect format from magic bytes when the content type is
        // generic (e.g. public.zip-archive, public.archive, public.data).
        // This handles files from SMB shares or Files.app where the system
        // assigns a broad type instead of our custom UTIs.
        if let result = try detectFromMagicBytes(data: data) {
            return result
        }

        throw DocumentError.unsupportedType
    }

    /// Decodes common text-file encodings without silently turning an
    /// unsupported or corrupt document into an empty book.
    nonisolated static func decodeText(_ data: Data) throws -> String {
        if data.isEmpty { return "" }

        var encodings: [String.Encoding] = [.utf8]
        let bytes = [UInt8](data.prefix(4_096))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            encodings.append(.utf32)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encodings.append(.utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encodings.append(.utf16BigEndian)
        } else if bytes.count >= 4, bytes.count.isMultiple(of: 2) {
            let pairs = bytes.count / 2
            let evenZeros = stride(from: 0, to: bytes.count, by: 2)
                .reduce(0) { $0 + (bytes[$1] == 0 ? 1 : 0) }
            let oddZeros = stride(from: 1, to: bytes.count, by: 2)
                .reduce(0) { $0 + (bytes[$1] == 0 ? 1 : 0) }
            if oddZeros * 3 > pairs { encodings.append(.utf16LittleEndian) }
            if evenZeros * 3 > pairs { encodings.append(.utf16BigEndian) }
        }
        encodings.append(contentsOf: [.windowsCP1252, .isoLatin1, .macOSRoman])
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), isPlausibleText(text) {
                return text
            }
        }
        throw DocumentError.parsingFailed("The text encoding is not supported or the file is not valid text.")
    }

    private nonisolated static func isPlausibleText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        var controls = 0
        var count = 0
        for scalar in text.unicodeScalars.prefix(4_096) {
            count += 1
            if scalar.value == 0
                || scalar.properties.generalCategory == .control
                    && scalar.value != 10 && scalar.value != 13 && scalar.value != 9 {
                controls += 1
            }
        }
        return count == 0 || Double(controls) / Double(count) < 0.05
    }

    /// Attempt to determine file format from leading bytes.
    private nonisolated static func detectFromMagicBytes(data: Data) throws -> DocumentContent? {
        guard data.count >= 4 else { return nil }
        let magic = [UInt8](data.prefix(4))

        // ZIP files (PK\x03\x04): could be ePub or CBZ
        if magic == [0x50, 0x4B, 0x03, 0x04] {
            // ePub ZIPs contain META-INF/container.xml — try ePub first
            if let book = try? EPubParser.parse(data: data) {
                return .epub(book)
            }
            // Otherwise treat as CBZ (zip of images)
            if let archive = try? ComicArchiveParser.parse(data: data) {
                return .comic(archive)
            }
        }

        // RAR files (Rar!\x1A\x07)
        if data.count >= 6, magic[0] == 0x52, magic[1] == 0x61, magic[2] == 0x72, magic[3] == 0x21 {
            let archive = try ComicArchiveParser.parseRAR(data: data)
            return .comic(archive)
        }

        // PDF (%PDF)
        if magic == [0x25, 0x50, 0x44, 0x46] {
            return .pdf(data)
        }

        return nil
    }
}

enum DocumentError: Error, LocalizedError {
    case unreadable
    case notWritable
    case unsupportedType
    case parsingFailed(String)
    case zipExtractionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file could not be read."
        case .notWritable: return "This app does not modify files."
        case .unsupportedType: return "This file type is not supported."
        case .parsingFailed(let detail): return "Parsing failed: \(detail)"
        case .zipExtractionFailed: return "Failed to extract archive."
        }
    }
}
