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
            return .markdown(try TextDecoder.decode(data))
        }
        if contentType.conforms(to: .plainText) || ext == "txt" {
            return .plainText(try TextDecoder.decode(data))
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
