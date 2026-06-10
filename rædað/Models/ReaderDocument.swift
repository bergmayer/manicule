import SwiftUI
import UniformTypeIdentifiers
import os.log

private nonisolated let docLog = Logger(subsystem: "com.palefire.raedad", category: "Document")

/// Read-only document model for all supported file types.
///
/// On macOS this is used with DocumentGroup(viewing:) which provides native
/// Open With / drag-and-drop / recent files support. On iOS the custom
/// IOSDocumentBrowser handles file opening and constructs ReaderDocument directly.
///
/// FILE TYPE REGISTRATION (Info.plist):
/// Each supported type needs three things working together:
///   1. CFBundleDocumentTypes entry — tells the system "I can open this type"
///   2. UTExportedTypeDeclarations (for types we define: CBZ, CBR, markdown) or
///      UTImportedTypeDeclarations (for types others define: net.daringfireball.markdown)
///   3. readableContentTypes here — tells SwiftUI's DocumentGroup what to accept
///
/// UTType conformance matters enormously on iOS. If an exported type conforms to
/// a system type (public.zip-archive, public.plain-text), the system's built-in
/// handler takes priority for Quick Look and other features. Our exported types
/// (com.raedad.cbz-archive, com.raedad.cbr-archive, com.raedad.markdown) conform
/// ONLY to public.data to avoid this.
///
/// LSHandlerRank in CFBundleDocumentTypes controls the "Open with" button:
///   Owner    = we define this type (CBZ, CBR, markdown)
///   Default  = standard handler (PDF)
///   Alternate = we can open it but aren't primary (plain text)
///
/// iOS "OPEN IN PLACE" (LSSupportsOpeningDocumentsInPlace=true, UISupportsDocumentBrowser=true):
/// Files.app grants a security-scoped URL. On macOS, DocumentGroup handles this
/// automatically. On iOS, IOSDocumentBrowser calls url.startAccessingSecurityScopedResource()
/// before reading data, then passes it to DocumentContent.parse().
struct ReaderDocument: FileDocument {
    static let readableContentTypes: [UTType] = {
        var types: [UTType] = [
            .pdf,
            .epub,
            .plainText,
            UTType(importedAs: "net.daringfireball.markdown"),
            UTType(exportedAs: "com.raedad.markdown"),
            .cbzArchive,
            .cbrArchive,
        ]

        // We can't control what UTType the system assigns to .cbz/.cbr files.
        // Other apps may export competing types and the system picks one per
        // extension. If another app wins, our custom type won't match.
        // Three layers of defense:
        //
        // 1. Parent types — any .cbz subtype conforms to public.zip-archive,
        //    any .cbr subtype conforms to com.rarlab.rar-archive.
        // 2. Extension-resolved types — UTType(filenameExtension:) returns
        //    whatever the system currently resolves, covering the specific
        //    competing type on this device.
        // 3. Our own exported types (already in the list above).

        // Layer 1: parent archive types
        if !types.contains(.zip) { types.append(.zip) }
        if let rar = UTType("com.rarlab.rar-archive") {
            if !types.contains(rar) { types.append(rar) }
        }

        // Layer 2: extension-resolved types (device-specific)
        if let cbzByExt = UTType(filenameExtension: "cbz") {
            if !types.contains(cbzByExt) { types.append(cbzByExt) }
        }
        if let cbrByExt = UTType(filenameExtension: "cbr") {
            if !types.contains(cbrByExt) { types.append(cbrByExt) }
        }

        return types
    }()

    let content: DocumentContent
    let rawData: Data

    /// Direct initializer for manual document construction (e.g. from security-scoped file access).
    init(content: DocumentContent, rawData: Data) {
        self.content = content
        self.rawData = rawData
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        let ct = configuration.contentType
        let filename = configuration.file.filename ?? configuration.file.preferredFilename
        docLog.info("ReaderDocument.init: type=\(ct.identifier), filename=\(filename ?? "nil", privacy: .public), isRegular=\(configuration.file.isRegularFile), isDir=\(configuration.file.isDirectory)")

        guard let data = configuration.file.regularFileContents else {
            docLog.error("ReaderDocument.init: regularFileContents is nil")
            throw DocumentError.parsingFailed(
                "File contents unavailable (type: \(ct.identifier), isRegular: \(configuration.file.isRegularFile), isDir: \(configuration.file.isDirectory))"
            )
        }
        docLog.info("ReaderDocument.init: data size=\(data.count) bytes")
        self.rawData = data
        let parsed = try DocumentContent.parse(
            data: data,
            contentType: ct,
            filename: filename
        )
        self.content = parsed
        docLog.info("ReaderDocument.init: parsed successfully")
    }

    // Required by protocol but never called for a viewing-only DocumentGroup.
    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw DocumentError.notWritable
    }
}
