import Foundation

nonisolated enum TextPreparation {
    struct Prepared: Sendable {
        let directory: TemporaryDirectoryLease
        let chunks: [String]
        let chunkSourceLines: [Int]
    }

    /// Creates a temporary HTML file for WebView display.
    /// Uses markdown-to-HTML conversion when rendering is enabled, otherwise escaped plain text.
    nonisolated static func prepare(_ rawText: String, reflow: Bool, markdown: Bool, hasFile: Bool) throws -> Prepared {
        try Task.checkCancellation()
        var text = rawText
        if reflow {
            text = TextReflow.reflow(text)
        }
        let sourceLines = sourceLineMap(rawText, displayedText: text)
        let bodyContent: String

        if markdown {
            bodyContent = MarkdownHTMLRenderer.render(text, headingAnchorPrefix: "toc-", includeSourceLines: true)
        } else {
            // Inline spans preserve the existing paragraph and line breaks.
            let lines = text.components(separatedBy: "\n")
            let marked = lines.enumerated().map { index, line in
                line.isEmpty ? "" : "<span data-source-line=\"\(sourceLines[index])\">\(escapeHTML(line))</span>"
            }.joined(separator: "\n")
            bodyContent = "<p>" + marked
                .replacingOccurrences(of: "\n\n", with: "</p><p>")
                .replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }

        let baseElement = markdown && hasFile
            ? "<base href=\"epub-local://document/\">" : ""

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src epub-local: data: https:; font-src epub-local: data:; connect-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'">
        \(baseElement)
        <style>
        body {
            background-color: #ffffff;
            color: #000000;
            margin: 0;
            padding: 16px;
            word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 1em; margin-bottom: 0.5em; }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.3em; }
        h4 { font-size: 1.1em; }
        pre { background: #f4f4f4; padding: 12px; border-radius: 4px; overflow-x: auto; }
        code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em; }
        :not(pre) > code { background: #f0f0f0; padding: 2px 4px; border-radius: 3px; }
        blockquote {
            border-left: 3px solid #ccc;
            margin: 0.5em 0;
            padding: 0.25em 1em;
            color: #555;
        }
        hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
        img { max-width: 100%; height: auto; }
        a { color: #0066cc; }
        </style>
        </head><body>\(bodyContent)</body></html>
        """

        try Task.checkCancellation()
        let directory = try TemporaryDirectoryLease.writing(Data(html.utf8), filename: "content.html")
        let textChunks = chunks(text)
        try Task.checkCancellation()
        return Prepared(directory: directory, chunks: textChunks,
                        chunkSourceLines: stride(from: 0, to: sourceLines.count, by: 100).map { sourceLines[$0] })
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
    nonisolated static func chunks(_ source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        let chunkSize = 100
        var chunks: [String] = []
        chunks.reserveCapacity((lines.count + chunkSize - 1) / chunkSize)
        var i = 0
        while i < lines.count {
            let end = min(i + chunkSize, lines.count)
            chunks.append(lines[i..<end].joined(separator: "\n"))
            i = end
        }
        return chunks
    }

}
