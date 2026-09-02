import SwiftUI

/// Routes to the appropriate reader view based on document content type.
struct DocumentViewer: View {
    let document: ReaderDocument
    let fileURL: URL?
    var onClose: (() -> Void)?
    @State private var showChrome: Bool = true

    var body: some View {
        Group {
            switch document.content {
            case .pdf(let data):
                PDFReaderView(data: data, fileURL: fileURL, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .epub(let book):
                EPubReaderView(book: book, fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .plainText(let text):
                TextReaderView(content: .plain(text), fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .markdown(let text):
                TextReaderView(content: .markdown(text), fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            case .comic(let archive):
                ComicReaderView(archive: archive, fileURL: fileURL, rawData: document.rawData, fileHash: document.fileHash, showChrome: $showChrome, onClose: onClose)
            }
        }
        #if !os(macOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
    }
}
