// Quick Look Preview Extension for ePub, CBZ, CBR, PDF, TXT, and Markdown files.
//
// ARCHITECTURE OVERVIEW:
// This is a QLPreviewProvider-based extension (QLIsDataBasedPreview=true in Info.plist).
// The system gives us raw file data, we return a QLPreviewReply (HTML, PDF, or raw data).
// Routing is done by file extension (request.fileURL.pathExtension), NOT by UTType.
//
// CRITICAL CONFIGURATION NOTES:
// 1. Use `#if os(iOS)` NOT `#if canImport(UIKit)` — UIKit is importable on
//    macOS (Apple Silicon) but causes UIKit_PKSubsystem setup failures.
// 2. Info.plist must have QLIsDataBasedPreview = true for QLPreviewProvider.
// 3. WKWebView cannot be used in QL extensions — WebProcess crashes in sandbox.
// 4. Extension deployment target must not exceed the SDK version.
//
// iOS QUICK LOOK VS SYSTEM HANDLERS (hard-won knowledge):
// iOS has built-in QL handlers for system types (plain-text, zip-archive, etc.)
// that ALWAYS take priority over third-party QL extensions. If your custom UTType
// conforms to a system type, the system handler will run instead of your extension.
// The fix: exported UTTypes must conform ONLY to `public.data` — NOT to
// `public.archive`, `public.zip-archive`, `public.plain-text`, etc.
// This is why com.raedad.cbz-archive conforms to public.data (not public.archive)
// and com.raedad.markdown conforms to public.data (not public.plain-text).
// Without this, CBZ files show the system archive browser and .md files show
// the system's unformatted plain text viewer instead of our rendered previews.
//
// QL EXTENSION SUPPORTED TYPES (Info.plist QLSupportedContentTypes):
// Lists our exported types (com.raedad.*) and parent archive types
// (public.zip-archive, com.rarlab.rar-archive) as conformance fallback.
// Setting rædað as the default handler for .cbz/.cbr ensures our QL
// extension is invoked. On iOS this is safe because the system handler
// issue is about our EXPORTED type's conformance chain (public.data only),
// not what QLSupportedContentTypes lists.
//
// PREVIEW REPLY FORMATS:
// - ePub, text, markdown: QLPreviewReply(dataOfContentType: .html) with cid:
//   image attachments. Renders as scrollable web content.
// - Comics (CBZ/CBR): QLPreviewReply(dataOfContentType: .html) with inline
//   base64 data: URIs (cid: attachments fail for large/numerous images).
// - PDF: QLPreviewReply(forPDFWithPageSize:) — pass-through to system renderer.
//
// macOS TESTING (qlmanage is broken on macOS 26):
// Must test via Finder (select file, press Space), NOT qlmanage.
// After rebuilding: killall rædað_look && pluginkit -a <appex-path> && qlmanage -r
import QuickLook
import UniformTypeIdentifiers
import PDFKit
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import QuickLookUI
#endif

/// CRITICAL: Must explicitly declare QLPreviewingController conformance.
/// QLPreviewProvider does NOT declare this conformance in its public ObjC header.
/// QuickLookUI's runtime check for QLIsDataBasedPreview=true extensions calls
/// conformsToProtocol:@protocol(QLPreviewingController) — without explicit
/// conformance the extension loads but fails with "The principal object does not
/// implement the QLPreviewingController protocol".
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()

        switch ext {
        case "epub":
            return try makeEPubPreview(data: data)
        case "cbz":
            return try makeCBZPreview(data: data, title: fileURL.deletingPathExtension().lastPathComponent)
        case "cbr":
            return try makeCBRPreview(data: data, title: fileURL.deletingPathExtension().lastPathComponent)
        case "pdf":
            return try makePDFPreview(data: data)
        case "md", "markdown":
            return try makeMarkdownPreview(data: data, title: fileURL.lastPathComponent)
        case "txt":
            return try makeTextPreview(data: data, title: fileURL.lastPathComponent)
        default:
            return try makePreviewFromMagicBytes(data: data)
        }
    }

    // MARK: - Magic Bytes Fallback

    /// Attempt to preview a file with an unknown extension by detecting format from magic bytes.
    private func makePreviewFromMagicBytes(data: Data) throws -> QLPreviewReply {
        guard data.count >= 4 else { throw PreviewError.unsupportedFormat }
        let magic = [UInt8](data.prefix(4))

        // ZIP (PK\x03\x04): try CBZ
        if magic == [0x50, 0x4B, 0x03, 0x04] {
            if (try? ComicArchiveParser.parseCBZ(data: data)) != nil {
                return try makeCBZPreview(data: data)
            }
        }

        // RAR (Rar!\x1A\x07)
        if data.count >= 6, magic[0] == 0x52, magic[1] == 0x61, magic[2] == 0x72, magic[3] == 0x21 {
            return try makeCBRPreview(data: data)
        }

        throw PreviewError.unsupportedFormat
    }

    // MARK: - ePub Preview (all chapters, scrollable HTML with cid: image attachments)

    private func makeEPubPreview(data: Data) throws -> QLPreviewReply {
        let book = try EPubParser.parse(data: data)

        var attachments: [String: QLPreviewReplyAttachment] = [:]
        var bodyParts: [String] = []

        // Load ALL spine chapters
        for i in 0..<book.spine.count {
            guard let chapterURL = book.fileURL(forSpineIndex: i) else { continue }
            guard var chapterHTML = try? String(contentsOf: chapterURL, encoding: .utf8) else { continue }
            let chapterDir = chapterURL.deletingLastPathComponent()

            // Replace image sources with cid: attachment references
            chapterHTML = Self.replaceImageSources(in: chapterHTML, baseDir: chapterDir, attachments: &attachments)

            // Inline linked CSS
            chapterHTML = Self.inlineLinkedCSS(in: chapterHTML, baseDir: chapterDir)

            // Extract body content to merge into single document
            if let bodyContent = Self.extractBodyContent(from: chapterHTML) {
                bodyParts.append(bodyContent)
            } else {
                bodyParts.append(chapterHTML)
            }
        }

        guard !bodyParts.isEmpty else { throw PreviewError.noContent }

        let title = book.metadata.title
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: Georgia, "Times New Roman", serif;
            font-size: 16px;
            line-height: 1.6;
            max-width: 700px;
            margin: 20px auto;
            padding: 0 20px;
            color: #333;
        }
        img { max-width: 100%; height: auto; }
        .chapter-break { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        </style>
        </head>
        <body>
        \(bodyParts.joined(separator: "\n<hr class=\"chapter-break\">\n"))
        </body>
        </html>
        """

        let htmlData = Data(fullHTML.utf8)
        let capturedAttachments = attachments

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 600, height: 800)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            replyToUpdate.attachments = capturedAttachments
            return htmlData
        }
        reply.title = title.isEmpty ? "ePub Preview" : title
        return reply
    }

    // MARK: - PDF Preview (pass-through)

    private func makePDFPreview(data: Data) throws -> QLPreviewReply {
        guard let pdfDoc = PDFDocument(data: data), pdfDoc.pageCount > 0 else {
            throw PreviewError.noContent
        }
        let pageSize = pdfDoc.page(at: 0)?.bounds(for: .mediaBox).size
            ?? CGSize(width: 612, height: 792)

        return QLPreviewReply(forPDFWithPageSize: pageSize) { _ in
            return pdfDoc
        }
    }

    // MARK: - Text Preview

    private func makeTextPreview(data: Data, title: String) throws -> QLPreviewReply {
        let text = try Self.decodeText(data)
        let escaped = Self.escapeHTML(text)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: Georgia, "Times New Roman", serif;
            font-size: 16px;
            line-height: 1.6;
            max-width: 700px;
            margin: 20px auto;
            padding: 0 20px;
            color: #333;
        }
        pre { white-space: pre-wrap; word-wrap: break-word; font-family: inherit; margin: 0; }
        </style>
        </head>
        <body><pre>\(escaped)</pre></body>
        </html>
        """
        let htmlData = Data(html.utf8)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 600, height: 800)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return htmlData
        }
        reply.title = title
        return reply
    }

    // MARK: - Markdown Preview

    private func makeMarkdownPreview(data: Data, title: String) throws -> QLPreviewReply {
        let text = try Self.decodeText(data)
        let rendered = Self.renderMarkdown(text)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: Georgia, "Times New Roman", serif;
            font-size: 16px;
            line-height: 1.6;
            max-width: 700px;
            margin: 20px auto;
            padding: 0 20px;
            color: #333;
        }
        h1 { font-size: 1.8em; margin-top: 1em; margin-bottom: 0.4em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; margin-top: 1.2em; margin-bottom: 0.4em; border-bottom: 1px solid #eee; padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; margin-top: 1.2em; margin-bottom: 0.4em; }
        h4, h5, h6 { font-size: 1em; margin-top: 1em; margin-bottom: 0.4em; }
        code { font-family: Menlo, Consolas, monospace; background: #f0f0f0; padding: 2px 5px; border-radius: 3px; font-size: 0.85em; }
        pre { background: #f6f6f6; border: 1px solid #e0e0e0; border-radius: 4px; margin: 1em 0; overflow-x: auto; }
        pre code { display: block; padding: 12px; background: none; border: none; border-radius: 0; }
        blockquote { border-left: 3px solid #ccc; margin: 1em 0; margin-left: 0; padding-left: 1em; color: #555; }
        ul, ol { padding-left: 2em; margin: 0.5em 0; }
        li { margin: 0.3em 0; }
        table { border-collapse: collapse; margin: 1em 0; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 6px 12px; text-align: left; }
        th { background: #f6f6f6; font-weight: bold; }
        img { max-width: 100%; height: auto; }
        hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        a { color: #0066cc; }
        </style>
        </head>
        <body>
        \(rendered)
        </body>
        </html>
        """
        let htmlData = Data(html.utf8)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 600, height: 800)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return htmlData
        }
        reply.title = title
        return reply
    }

    // MARK: - Comic Previews (scrollable HTML with stacked images)

    private func makeCBZPreview(data: Data, title: String = "CBZ") throws -> QLPreviewReply {
        let archive = try ComicArchiveParser.parseCBZ(data: data)
        return try makeComicHTMLReply(pages: archive.pages, title: title)
    }

    private func makeCBRPreview(data: Data, title: String = "CBR") throws -> QLPreviewReply {
        let archive = try ComicArchiveParser.parseCBR(data: data)
        return try makeComicHTMLReply(pages: archive.pages, title: title)
    }

    /// Renders comic pages as a vertically scrollable HTML document with inline base64 images.
    /// Uses data: URIs instead of cid: attachments — cid: fails silently for numerous/large
    /// images, producing a blank preview. Images are downscaled to keep memory reasonable.
    private func makeComicHTMLReply(pages: [URL], title: String = "Comic Preview") throws -> QLPreviewReply {
        guard !pages.isEmpty else {
            throw PreviewError.noContent
        }

        let previewPages = Array(pages.prefix(10))
        var imgTags: [String] = []

        for (i, pageURL) in previewPages.enumerated() {
            guard let imageData = try? Data(contentsOf: pageURL) else { continue }

            // Downscale large images to ~1200px max dimension for memory efficiency
            let processedData: Data
            let mimeType: String
            if let downscaled = Self.downscaleImage(imageData, maxDimension: 1200) {
                processedData = downscaled
                mimeType = "image/jpeg"
            } else {
                processedData = imageData
                mimeType = Self.imageMIMEType(for: pageURL.pathExtension)
            }

            let base64 = processedData.base64EncodedString()
            imgTags.append("""
                <div class="page">
                    <img src="data:\(mimeType);base64,\(base64)">
                    <div class="label">\(i + 1) / \(pages.count)</div>
                </div>
                """)
        }

        guard !imgTags.isEmpty else { throw PreviewError.noContent }

        let truncationNote = pages.count > previewPages.count
            ? "<p class=\"note\">Showing \(previewPages.count) of \(pages.count) pages</p>"
            : ""

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            margin: 0;
            padding: 0;
            background: #1c1c1e;
        }
        .page { position: relative; margin-bottom: 2px; }
        .page img { display: block; width: 100%; height: auto; }
        .label {
            position: absolute; bottom: 8px; right: 8px;
            background: rgba(0,0,0,0.6); color: #ccc;
            font: 12px -apple-system, sans-serif;
            padding: 2px 8px; border-radius: 4px;
        }
        .note {
            text-align: center; color: #999;
            font: 14px -apple-system, sans-serif;
            padding: 20px;
        }
        </style>
        </head>
        <body>
        \(imgTags.joined(separator: "\n"))
        \(truncationNote)
        </body>
        </html>
        """

        let htmlData = Data(html.utf8)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 600, height: 800)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return htmlData
        }
        reply.title = title
        return reply
    }

    /// Downscales an image to fit within maxDimension, returning JPEG data.
    /// Returns nil if the image is already small enough or can't be processed.
    private static func downscaleImage(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              max(width, height) > Double(maxDimension) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.75
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Returns MIME type string for common image extensions.
    private static func imageMIMEType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png":  return "image/png"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        default:     return "image/jpeg"
        }
    }

    // MARK: - HTML Processing

    private static func extractBodyContent(from html: String) -> String? {
        guard let bodyStart = html.range(of: "<body", options: .caseInsensitive) else { return nil }
        guard let bodyTagEnd = html[bodyStart.upperBound...].range(of: ">") else { return nil }
        guard let bodyClose = html.range(of: "</body>", options: .caseInsensitive) else {
            return String(html[bodyTagEnd.upperBound...])
        }
        return String(html[bodyTagEnd.upperBound..<bodyClose.lowerBound])
    }

    /// Replaces <img src="relative/path"> with <img src="cid:attachment-N"> and populates attachments.
    /// Also converts SVG <image xlink:href="..."> elements to <img> tags with cid: attachments.
    private static func replaceImageSources(
        in html: String,
        baseDir: URL,
        attachments: inout [String: QLPreviewReplyAttachment]
    ) -> String {
        var result = html

        // First: convert SVG <image> elements to <img> tags (cid: URLs don't work in SVG)
        result = replaceSVGImages(in: result, baseDir: baseDir, attachments: &attachments)

        // Then: handle regular <img src="..."> elements
        let pattern = #"(<img[^>]+src\s*=\s*)(["'])([^"']+)(["'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return result
        }

        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 5 else { continue }
            let srcPath = nsString.substring(with: match.range(at: 3))

            if srcPath.hasPrefix("data:") || srcPath.hasPrefix("http") || srcPath.hasPrefix("cid:") { continue }

            let resolved = baseDir.appendingPathComponent(srcPath).standardized
            guard FileManager.default.fileExists(atPath: resolved.path),
                  let imageData = try? Data(contentsOf: resolved) else { continue }

            let attachmentID = "img-\(attachments.count)"
            let utType = imageUTType(for: resolved.pathExtension)
            attachments[attachmentID] = QLPreviewReplyAttachment(data: imageData, contentType: utType)

            let prefix = nsString.substring(with: match.range(at: 1))
            let quote = nsString.substring(with: match.range(at: 2))
            let replacement = "\(prefix)\(quote)cid:\(attachmentID)\(quote)"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    /// Replaces <svg>...<image xlink:href="path"/>...</svg> blocks with <img src="cid:..."> tags.
    private static func replaceSVGImages(
        in html: String,
        baseDir: URL,
        attachments: inout [String: QLPreviewReplyAttachment]
    ) -> String {
        var result = html
        // Match SVG blocks containing image elements with xlink:href
        let svgPattern = #"<svg[^>]*>[\s\S]*?<image[^>]+(?:xlink:)?href\s*=\s*["']([^"']+)["'][^>]*/?>[\s\S]*?</svg>"#
        guard let regex = try? NSRegularExpression(pattern: svgPattern, options: .caseInsensitive) else {
            return result
        }

        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let srcPath = nsString.substring(with: match.range(at: 1))

            if srcPath.hasPrefix("data:") || srcPath.hasPrefix("http") { continue }

            let resolved = baseDir.appendingPathComponent(srcPath).standardized
            guard FileManager.default.fileExists(atPath: resolved.path),
                  let imageData = try? Data(contentsOf: resolved) else { continue }

            let attachmentID = "img-\(attachments.count)"
            let utType = imageUTType(for: resolved.pathExtension)
            attachments[attachmentID] = QLPreviewReplyAttachment(data: imageData, contentType: utType)

            let replacement = "<img src=\"cid:\(attachmentID)\" style=\"max-width:100%;height:auto\">"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    private static func inlineLinkedCSS(in html: String, baseDir: URL) -> String {
        var result = html
        let pattern = #"<link[^>]+rel\s*=\s*["']stylesheet["'][^>]+href\s*=\s*["']([^"']+)["'][^>]*/?\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return result
        }

        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let cssPath = nsString.substring(with: match.range(at: 1))
            let resolved = baseDir.appendingPathComponent(cssPath).standardized

            guard let cssContent = try? String(contentsOf: resolved, encoding: .utf8) else { continue }
            let styleBlock = "<style>\(cssContent)</style>"
            result = (result as NSString).replacingCharacters(in: match.range, with: styleBlock)
        }

        return result
    }

    // MARK: - Helpers

    private static func imageUTType(for pathExtension: String) -> UTType {
        switch pathExtension.lowercased() {
        case "png":   return .png
        case "gif":   return .gif
        case "webp":  return .webP
        case "bmp":   return .bmp
        case "tiff":  return .tiff
        default:      return .jpeg
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Simple markdown-to-HTML conversion for Quick Look previews.
    private static func renderMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var html: [String] = []
        var inCodeBlock = false
        var listType: String? = nil  // "ul" or "ol"
        var paragraph: [String] = []
        var tableRows: [[String]] = []
        var tableHasHeader = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            html.append("<p>\(inlineMarkdown(joined))</p>")
            paragraph.removeAll()
        }

        func closePendingList() {
            if let tag = listType {
                html.append("</\(tag)>")
                listType = nil
            }
        }

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            html.append("<table>")
            for (i, row) in tableRows.enumerated() {
                if i == 0 && tableHasHeader {
                    html.append("<thead><tr>")
                    for cell in row { html.append("<th>\(inlineMarkdown(escapeHTML(cell)))</th>") }
                    html.append("</tr></thead><tbody>")
                } else {
                    html.append("<tr>")
                    for cell in row { html.append("<td>\(inlineMarkdown(escapeHTML(cell)))</td>") }
                    html.append("</tr>")
                }
            }
            if tableHasHeader { html.append("</tbody>") }
            html.append("</table>")
            tableRows.removeAll()
            tableHasHeader = false
        }

        let orderedListPattern = try? NSRegularExpression(pattern: #"^\d+\.\s+"#)

        for line in lines {
            // Fenced code blocks
            if line.hasPrefix("```") {
                flushParagraph()
                closePendingList()
                flushTable()
                inCodeBlock.toggle()
                html.append(inCodeBlock ? "<pre><code>" : "</code></pre>")
                continue
            }
            if inCodeBlock {
                html.append(escapeHTML(line))
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Table rows (pipe-delimited)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                flushParagraph()
                closePendingList()
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Separator row (---|---|---) — marks previous row as header
                if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) && !$0.isEmpty }) {
                    tableHasHeader = true
                    continue
                }
                tableRows.append(cells)
                continue
            } else if !tableRows.isEmpty {
                flushTable()
            }

            // Blank line — flush paragraph
            if trimmed.isEmpty {
                flushParagraph()
                closePendingList()
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                flushParagraph()
                closePendingList()
                var level = 0
                for ch in trimmed { if ch == "#" { level += 1 } else { break } }
                level = min(level, 6)
                let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inlineMarkdown(escapeHTML(content)))</h\(level)>")
                continue
            }

            // Horizontal rules
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }),
               trimmed.filter({ $0 != " " }).count >= 3 {
                let chars = Set(trimmed.filter { $0 != " " })
                if chars.count == 1 {
                    flushParagraph()
                    closePendingList()
                    html.append("<hr>")
                    continue
                }
            }

            // Blockquotes
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closePendingList()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                html.append("<blockquote><p>\(inlineMarkdown(escapeHTML(content)))</p></blockquote>")
                continue
            }

            // Unordered lists
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                if listType != "ul" {
                    closePendingList()
                    html.append("<ul>")
                    listType = "ul"
                }
                let content = String(trimmed.dropFirst(2))
                html.append("<li>\(inlineMarkdown(escapeHTML(content)))</li>")
                continue
            }

            // Ordered lists
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = orderedListPattern?.firstMatch(in: trimmed, range: nsRange) {
                flushParagraph()
                if listType != "ol" {
                    closePendingList()
                    html.append("<ol>")
                    listType = "ol"
                }
                let matchEnd = trimmed.index(trimmed.startIndex, offsetBy: match.range.length)
                let content = String(trimmed[matchEnd...])
                html.append("<li>\(inlineMarkdown(escapeHTML(content)))</li>")
                continue
            }

            // Regular text — collect into paragraph
            closePendingList()
            paragraph.append(escapeHTML(trimmed))
        }

        flushParagraph()
        closePendingList()
        flushTable()
        if inCodeBlock { html.append("</code></pre>") }

        return html.joined(separator: "\n")
    }

    /// Converts inline markdown (bold, italic, code, links, images, strikethrough) to HTML.
    private static func inlineMarkdown(_ text: String) -> String {
        var result = text
        // Code spans (before other inline to avoid conflicts)
        result = result.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression)
        // Strikethrough
        result = result.replacingOccurrences(
            of: #"~~(.+?)~~"#,
            with: "<del>$1</del>",
            options: .regularExpression)
        // Bold
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"__(.+?)__"#,
            with: "<strong>$1</strong>",
            options: .regularExpression)
        // Italic
        result = result.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\b_(.+?)_\b"#,
            with: "<em>$1</em>",
            options: .regularExpression)
        // Images (before links — ![alt](url) vs [text](url))
        result = result.replacingOccurrences(
            of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
            with: "<img src=\"$2\" alt=\"$1\">",
            options: .regularExpression)
        // Links
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression)
        return result
    }

    private static func decodeText(_ data: Data) throws -> String {
        if data.isEmpty { return "" }
        let bytes = [UInt8](data.prefix(4_096))
        var encodings: [String.Encoding] = [.utf8]
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
            if let text = String(data: data, encoding: encoding) {
                let sample = text.unicodeScalars.prefix(4_096)
                let count = sample.count
                let controls = sample.reduce(into: 0) { result, scalar in
                    if scalar.value == 0
                        || scalar.properties.generalCategory == .control
                            && scalar.value != 9 && scalar.value != 10 && scalar.value != 13 {
                        result += 1
                    }
                }
                if count == 0 || Double(controls) / Double(count) < 0.05 { return text }
            }
        }
        throw PreviewError.noContent
    }
}

private enum PreviewError: Error, LocalizedError {
    case noContent
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noContent: return "No content found in the file."
        case .unsupportedFormat: return "This file format is not supported for preview."
        }
    }
}
