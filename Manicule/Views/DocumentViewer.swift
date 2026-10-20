import SwiftUI

/// Routes to the appropriate reader view based on document content type.
struct DocumentViewer: View {
    let document: ReaderDocument
    let fileURL: URL?
    var onClose: (() -> Void)?
    @State private var showChrome: Bool = true
    @State private var readingSession: ReadingSession?

    var body: some View {
        Group {
            switch document.content {
            case .pdf(let data):
                PDFReaderView(data: data, fileURL: fileURL, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .epub(let book):
                FlowingReaderView(source: .epub(book), fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .plainText(let text):
                FlowingReaderView(source: .plain(text), fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .markdown(let text):
                FlowingReaderView(source: .markdown(text), fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .comic(let archive):
                ComicReaderView(archive: archive, fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            }
        }
        // DocumentGroup can deliver a new snapshot at the same file URL.
        // Reader tasks and restoration state belong to that snapshot.
        .id(document.fileHash)
        .environment(\.readingSession, readingSession)
        .task(id: document.fileHash) {
            ReaderHelpers.migrateLegacyIdentity(data: document.rawData, currentHash: document.fileHash)
            readingSession = fileURL.flatMap { BookmarkStore.shared.beginReading(document, at: $0) }
        }
        #if !os(macOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
    }
}
