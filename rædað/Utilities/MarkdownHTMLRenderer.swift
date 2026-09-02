import Foundation

/// Small, dependency-free Markdown renderer shared by the reader and Quick Look.
/// It intentionally supports the subset needed for local document previews.
enum MarkdownHTMLRenderer {
    private struct Cursor {
        let lines: [String]
        var index = 0
        var headingIndex = 0
    }

    nonisolated static func render(
        _ markdown: String,
        headingAnchorPrefix: String? = nil
    ) -> String {
        var cursor = Cursor(lines: markdown.components(separatedBy: "\n"))
        var html: [String] = []

        while cursor.index < cursor.lines.count {
            let trimmed = trim(cursor.lines[cursor.index])
            if trimmed.isEmpty {
                cursor.index += 1
            } else if trimmed.hasPrefix("```") {
                html.append(renderFencedCode(cursor: &cursor))
            } else if isTableRow(trimmed) {
                html.append(renderTable(cursor: &cursor))
            } else if let heading = parseHeading(trimmed) {
                html.append(renderHeading(
                    heading,
                    index: cursor.headingIndex,
                    anchorPrefix: headingAnchorPrefix
                ))
                cursor.headingIndex += 1
                cursor.index += 1
            } else if isHorizontalRule(trimmed) {
                html.append("<hr>")
                cursor.index += 1
            } else if isBlockquote(trimmed) {
                html.append(renderBlockquote(cursor: &cursor))
            } else if isUnorderedListItem(trimmed) {
                html.append(renderList(cursor: &cursor, ordered: false))
            } else if parseOrderedListItem(trimmed) != nil {
                html.append(renderList(cursor: &cursor, ordered: true))
            } else {
                html.append(renderParagraph(cursor: &cursor))
            }
        }

        return html.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private nonisolated static func renderFencedCode(cursor: inout Cursor) -> String {
        cursor.index += 1
        var code: [String] = []
        while cursor.index < cursor.lines.count {
            let line = cursor.lines[cursor.index]
            if trim(line).hasPrefix("```") {
                cursor.index += 1
                break
            }
            code.append(escapeHTML(line))
            cursor.index += 1
        }
        return "<pre><code>" + code.joined(separator: "\n") + "</code></pre>"
    }

    private nonisolated static func renderHeading(
        _ heading: (level: Int, text: String),
        index: Int,
        anchorPrefix: String?
    ) -> String {
        let identifier = anchorPrefix.map { " id=\"\($0)\(index)\"" } ?? ""
        return "<h\(heading.level)\(identifier)>\(inline(heading.text))</h\(heading.level)>"
    }

    private nonisolated static func renderBlockquote(cursor: inout Cursor) -> String {
        var lines: [String] = []
        while cursor.index < cursor.lines.count {
            let line = trim(cursor.lines[cursor.index])
            guard isBlockquote(line) else { break }
            lines.append(line == ">" ? "" : String(line.dropFirst(2)))
            cursor.index += 1
        }
        let content = lines.map(inline).joined(separator: "<br>")
        return "<blockquote>\(content)</blockquote>"
    }

    private nonisolated static func renderList(cursor: inout Cursor, ordered: Bool) -> String {
        let tag = ordered ? "ol" : "ul"
        var items: [String] = []
        while cursor.index < cursor.lines.count {
            let line = trim(cursor.lines[cursor.index])
            let item = ordered ? parseOrderedListItem(line) : unorderedListItem(line)
            guard let item else { break }
            items.append("<li>\(inline(item))</li>")
            cursor.index += 1
        }
        consumeSingleBlankLine(cursor: &cursor)
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private nonisolated static func renderTable(cursor: inout Cursor) -> String {
        var rows: [[String]] = []
        while cursor.index < cursor.lines.count {
            let line = trim(cursor.lines[cursor.index])
            guard let cells = tableCells(line) else { break }
            rows.append(cells)
            cursor.index += 1
        }

        let hasHeader = rows.count > 1 && isTableSeparator(rows[1])
        if hasHeader { rows.remove(at: 1) }
        guard !rows.isEmpty else { return "" }

        var html = "<table>"
        if hasHeader {
            html += "<thead>\(renderTableRow(rows.removeFirst(), cellTag: "th"))</thead>"
        }
        if !rows.isEmpty {
            html += "<tbody>"
            for row in rows {
                html += renderTableRow(row, cellTag: "td")
            }
            html += "</tbody>"
        }
        return html + "</table>"
    }

    private nonisolated static func renderTableRow(_ cells: [String], cellTag: String) -> String {
        let content = cells.map { "<\(cellTag)>\(inline($0))</\(cellTag)>" }.joined()
        return "<tr>\(content)</tr>"
    }

    private nonisolated static func renderParagraph(cursor: inout Cursor) -> String {
        var lines: [String] = []
        while cursor.index < cursor.lines.count {
            let line = trim(cursor.lines[cursor.index])
            guard !line.isEmpty, !isBlockStart(line) else { break }
            lines.append(inline(line))
            cursor.index += 1
        }
        consumeSingleBlankLine(cursor: &cursor)
        return lines.isEmpty ? "" : "<p>\(lines.joined(separator: " "))</p>"
    }

    private nonisolated static func consumeSingleBlankLine(cursor: inout Cursor) {
        guard cursor.index < cursor.lines.count,
              trim(cursor.lines[cursor.index]).isEmpty else { return }
        cursor.index += 1
    }

    private nonisolated static func isBlockStart(_ line: String) -> Bool {
        line.hasPrefix("```")
            || parseHeading(line) != nil
            || isHorizontalRule(line)
            || isBlockquote(line)
            || isUnorderedListItem(line)
            || parseOrderedListItem(line) != nil
            || isTableRow(line)
    }

    nonisolated static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let marks = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(marks.count),
              line.dropFirst(marks.count).first == " " else { return nil }
        return (marks.count, String(line.dropFirst(marks.count + 1)))
    }

    private nonisolated static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3, let marker = stripped.first else { return false }
        return ["-", "*", "_"].contains(marker)
            && stripped.allSatisfy { $0 == marker }
    }

    private nonisolated static func isBlockquote(_ line: String) -> Bool {
        line == ">" || line.hasPrefix("> ")
    }

    private nonisolated static func isUnorderedListItem(_ line: String) -> Bool {
        unorderedListItem(line) != nil
    }

    private nonisolated static func unorderedListItem(_ line: String) -> String? {
        guard line.count >= 2,
              let marker = line.first,
              "-*+".contains(marker),
              line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private nonisolated static func parseOrderedListItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        let afterDot = line.index(after: dot)
        guard !number.isEmpty,
              number.allSatisfy(\.isNumber),
              afterDot < line.endIndex,
              line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private nonisolated static func isTableRow(_ line: String) -> Bool {
        tableCells(line) != nil
    }

    private nonisolated static func tableCells(_ line: String) -> [String]? {
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return nil }
        return line.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { trim(String($0)) }
    }

    private nonisolated static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
        }
    }

    private nonisolated static func inline(_ text: String) -> String {
        var result = escapeHTML(text)
        var codeSpans: [String] = []
        while let range = result.range(of: "`([^`]+)`", options: .regularExpression) {
            let placeholder = "\u{FFFC}CODE\(codeSpans.count)\u{FFFC}"
            codeSpans.append(String(result[range].dropFirst().dropLast()))
            result.replaceSubrange(range, with: placeholder)
        }

        let replacements = [
            (#"~~(.+?)~~"#, "<del>$1</del>"),
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"__(.+?)__"#, "<strong>$1</strong>"),
            (#"\*(.+?)\*"#, "<em>$1</em>"),
            (#"(?<![\w])_(.+?)_(?![\w])"#, "<em>$1</em>"),
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "<img src=\"$2\" alt=\"$1\">"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in replacements {
            result = replace(result, pattern: pattern, template: template)
        }
        for (index, span) in codeSpans.enumerated() {
            result = result.replacingOccurrences(
                of: "\u{FFFC}CODE\(index)\u{FFFC}",
                with: "<code>\(span)</code>"
            )
        }
        return result
    }

    private nonisolated static func replace(
        _ input: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private nonisolated static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private nonisolated static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
