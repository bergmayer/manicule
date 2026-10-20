import Foundation

/// Converts text into a sectioned publication for the same Foliate renderer as
/// EPUB. Generated files are immutable and owned by one temporary-directory lease.
nonisolated enum TextPreparation {
    struct Prepared: Sendable {
        let directory: TemporaryDirectoryLease
        let tableOfContents: [EPubBook.TOCEntry]
    }

    private struct Block {
        let html: String
        let firstLine: Int
        let lastLine: Int
        var offset = 0
        var heading: Int? = nil
    }
    private struct Section: Encodable {
        let href: String
        let size: Int
        let firstLine: Int
        let firstOffset: Int
    }
    private struct Entry: Encodable {
        let label: String
        let href: String
    }
    private struct Publication: Encodable {
        let title: String
        let sections: [Section]
        let toc: [Entry]
    }

    static func prepare(_ rawText: String, reflow: Bool, markdown: Bool,
                        hasFile: Bool, title: String = "Document",
                        markdownSource: Bool = false) throws -> Prepared {
        try Task.checkCancellation()
        let text = reflow ? TextReflow.reflow(rawText) : rawText
        let sourceLines = sourceLineMap(rawText, displayedText: text)
        let blocks: [Block]
        if markdown {
            blocks = MarkdownHTMLRenderer.blocks(text, headingAnchorPrefix: "toc-", includeSourceLines: true).map {
                Block(html: $0.html, firstLine: $0.sourceLine, lastLine: $0.endLine, heading: $0.headingIndex)
            }
        } else {
            // Group lines into paragraphs, retaining source locations for mode
            // switches and old bookmarks. Bound raw blocks even without blank lines.
            var paragraphs: [Block] = [], lines: [String] = []
            var length = 0, startLine = 0, endLine = 0
            func finishParagraph() {
                if !lines.isEmpty {
                    paragraphs.append(Block(html: "<p>" + lines.joined(separator: "<br>") + "</p>",
                        firstLine: startLine, lastLine: endLine))
                }
                lines = []; length = 0
            }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                try Task.checkCancellation()
                if line.isEmpty || length >= 32_768 { finishParagraph() }
                guard !line.isEmpty else { continue }
                let sourceLine = sourceLines[index]
                // A minified or newline-free file must not force one enormous
                // layout frame. UTF-16 offsets preserve anchors across its slices.
                if line.utf8.count > 32_768 {
                    finishParagraph()
                    var start = line.startIndex, offset = 0
                    while start < line.endIndex {
                        try Task.checkCancellation()
                        let end = line.index(start, offsetBy: 8192, limitedBy: line.endIndex) ?? line.endIndex
                        let part = String(line[start..<end])
                        let span = "<p class=\"text-slice\"><span data-source-line=\"\(sourceLine)\" data-source-offset=\"\(offset)\">\(escapeHTML(part))</span></p>"
                        paragraphs.append(Block(html: span, firstLine: sourceLine, lastLine: sourceLine, offset: offset))
                        offset += part.utf16.count
                        start = end
                    }
                } else {
                    if lines.isEmpty { startLine = sourceLine }
                    endLine = sourceLine
                    lines.append("<span id=\"line-\(sourceLine)\" data-source-line=\"\(sourceLine)\">\(escapeHTML(line))</span>")
                    length += line.utf8.count
                }
            }
            finishParagraph()
            blocks = paragraphs
        }
        let directory = try TemporaryDirectoryLease.create(prefix: "manicule-text")
        var sections: [Section] = [], toc: [Entry] = []
        var pending: [String] = [], pendingSize = 0
        var firstLine = 0, firstOffset = 0
        var headingCursor = 0
        var headings: [(Int, String)] = []
        if markdown || markdownSource {
            var inFence = false
            for (line, value) in rawText.components(separatedBy: "\n").enumerated() {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") { inFence.toggle(); continue }
                if !inFence, let (_, title) = MarkdownHTMLRenderer.parseHeading(trimmed) {
                    headings.append((line, title))
                }
            }
        }
        func flush() throws {
            try Task.checkCancellation()
            let href = sections.isEmpty ? "content.html" : "section-\(sections.count).html"
            let body = pending.isEmpty ? "<p data-source-line=\"0\"><br></p>" : pending.joined(separator: "\n")
            let base = hasFile ? "<base href=\"epub-local://document/\">" : ""
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src epub-local: data: https:; font-src epub-local: data:; connect-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'">
            \(base)
            <style>
            body { margin: 0; overflow-wrap: break-word; }
            p.text-slice { margin-block: 0; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; }
            code { font-family: 'SF Mono', Menlo, monospace; }
            img, table { max-width: 100%; }
            blockquote { border-inline-start: 3px solid currentColor; padding-inline-start: 1em; }
            </style></head><body>\(body)</body></html>
            """
            try Data(html.utf8).write(to: directory.url.appendingPathComponent(href), options: .atomic)
            sections.append(Section(href: href, size: max(1, pendingSize), firstLine: firstLine, firstOffset: firstOffset))
            pending = []; pendingSize = 0
        }
        for block in blocks {
            try Task.checkCancellation()
            let count = block.html.utf8.count
            if pendingSize >= 65_536 { try flush() }
            if pending.isEmpty { firstLine = block.firstLine; firstOffset = block.offset }
            let href = sections.isEmpty ? "content.html" : "section-\(sections.count).html"
            if markdown, let index = block.heading, headings.indices.contains(index) {
                toc.append(Entry(label: headings[index].1, href: "\(href)#toc-\(index)"))
            } else if markdownSource && !markdown {
                while headingCursor < headings.count && headings[headingCursor].0 <= block.lastLine {
                    let (line, label) = headings[headingCursor]
                    if line >= block.firstLine { toc.append(Entry(label: label, href: "\(href)#line-\(line)")) }
                    headingCursor += 1
                }
            }
            pending.append(block.html); pendingSize += count
        }
        if !pending.isEmpty || sections.isEmpty { try flush() }
        let manifest = Publication(title: title, sections: sections, toc: toc)
        try JSONEncoder().encode(manifest).write(to: directory.url.appendingPathComponent("publication.json"), options: .atomic)
        try Task.checkCancellation()
        return Prepared(directory: directory, tableOfContents: toc.enumerated().map { index, entry in
            EPubBook.TOCEntry(id: "text-\(index)", title: entry.label, href: entry.href, children: [])
        })
    }

    /// Reflow changes whitespace only. Walk the source once to associate each
    /// displayed line with its original line, including repeated paragraphs.
    static func sourceLineMap(_ source: String, displayedText: String) -> [Int] {
        if source == displayedText { return Array(source.components(separatedBy: "\n").indices) }
        var cursor = source.startIndex
        var sourceLine = 0
        return displayedText.components(separatedBy: "\n").map { line in
            var firstLine: Int?
            for character in line where !character.isWhitespace {
                while cursor < source.endIndex && source[cursor].isWhitespace {
                    if source[cursor].isNewline { sourceLine += 1 }
                    source.formIndex(after: &cursor)
                }
                if firstLine == nil { firstLine = sourceLine }
                if cursor < source.endIndex { source.formIndex(after: &cursor) }
            }
            return firstLine ?? sourceLine
        }
    }

    nonisolated private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
