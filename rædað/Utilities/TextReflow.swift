import Foundation

/// Reflows Project Gutenberg-style plain text by stripping artificial hard line breaks
/// while preserving structural breaks that define the document's layout.
///
/// Hard-wrapped text (typically at 70-80 characters) is merged into flowing paragraphs.
/// Structural elements like headers, poetry, indented blocks, and paragraph boundaries
/// are preserved.
enum TextReflow {

    /// Reflows hard-wrapped plain text into flowing paragraphs.
    ///
    /// Rules applied:
    /// - Two or more consecutive newlines are preserved as paragraph boundaries.
    /// - Lines starting with 2+ spaces are treated as structural elements (kept separate).
    /// - Lines shorter than the short-line threshold are treated as complete units
    ///   (headers, poetry, list items) and end the current merge run.
    /// - Consecutive "full-length" lines are merged with a single space.
    /// - Double spaces in the output are collapsed to single spaces.
    static func reflow(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = splitIntoBlocks(normalized)

        let reflowed = blocks.map { block -> String in
            if block.isBlankSeparator {
                return block.text
            }
            return reflowBlock(block.text)
        }.joined()

        return collapseSpaces(reflowed)
    }

    // MARK: - Block splitting

    /// A chunk of text that is either content or a blank-line separator.
    private struct Block {
        let text: String
        let isBlankSeparator: Bool
    }

    /// Splits text into alternating content blocks and blank-line separators.
    /// Preserves the exact number of blank lines between paragraphs.
    private static func splitIntoBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < lines.count {
            if lines[i].allSatisfy(\.isWhitespace) {
                // Consume consecutive blank lines.
                // Start with "\n\n": one for the preceding content line's terminator
                // (lost during split) and one for this blank line itself.
                var blanks = "\n\n"
                i += 1
                while i < lines.count && lines[i].allSatisfy(\.isWhitespace) {
                    blanks += "\n"
                    i += 1
                }
                blocks.append(Block(text: blanks, isBlankSeparator: true))
            } else {
                // Consume consecutive non-blank lines
                var contentLines: [String] = []
                while i < lines.count && !lines[i].allSatisfy(\.isWhitespace) {
                    contentLines.append(lines[i])
                    i += 1
                }
                blocks.append(Block(text: contentLines.joined(separator: "\n"), isBlankSeparator: false))
            }
        }

        return blocks
    }

    // MARK: - Block reflow

    /// The short-line threshold. Lines with trimmed length below this
    /// are treated as structural (headers, poetry, list items).
    private static let shortLineThreshold = 50

    /// The minimum number of "full-length" lines a block must have
    /// to be considered hard-wrapped prose worth reflowing.
    private static let minFullLinesForReflow = 2

    /// Reflows a single content block (no blank lines within it).
    private static func reflowBlock(_ block: String) -> String {
        let lines = block.components(separatedBy: "\n")
        guard lines.count > 1 else { return block }

        // If every line shares the same leading indent, strip it before reflowing
        // and treat the block as normal prose. This handles Gutenberg texts where
        // entire sections (e.g. "EXTRACTS") are uniformly indented.
        let strippedLines: [String]
        if let common = commonIndent(lines), common >= 2 {
            strippedLines = lines.map { String($0.dropFirst(min(common, $0.count))) }
        } else {
            strippedLines = lines
        }

        // Detect whether this block looks like hard-wrapped prose.
        // If most lines are short, it's likely poetry, a title page, or a list — keep as-is.
        let fullLengthCount = strippedLines.filter { trimmedLength($0) >= shortLineThreshold }.count
        if fullLengthCount < minFullLinesForReflow {
            return block
        }

        var result: [String] = []
        var buffer = ""

        for line in strippedLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isIndented = hasStructuralIndent(line)
            let isShort = trimmed.count < shortLineThreshold

            // Indented line: new structural element
            if isIndented {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(line)
                continue
            }

            // Append to merge buffer
            if buffer.isEmpty {
                buffer = trimmed
            } else {
                buffer += " " + trimmed
            }

            // Short line ends the current merge run
            if isShort {
                result.append(buffer)
                buffer = ""
            }
        }

        if !buffer.isEmpty {
            result.append(buffer)
        }

        return result.joined(separator: "\n")
    }

    /// Returns the number of leading spaces shared by all non-empty lines, or nil if none.
    private static func commonIndent(_ lines: [String]) -> Int? {
        var minIndent = Int.max
        for line in lines {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            let spaces = line.prefix(while: { $0 == " " }).count
            minIndent = min(minIndent, spaces)
            if minIndent == 0 { return nil }
        }
        return minIndent == Int.max ? nil : minIndent
    }

    // MARK: - Helpers

    /// Returns the trimmed (non-whitespace) character count of a line.
    private static func trimmedLength(_ line: String) -> Int {
        line.trimmingCharacters(in: .whitespaces).count
    }

    /// Checks if a line starts with 2+ spaces (structural indent).
    private static func hasStructuralIndent(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        let idx = line.index(line.startIndex, offsetBy: 2)
        return line[line.startIndex..<idx].allSatisfy { $0 == " " }
    }

    /// Collapses runs of 2+ spaces into a single space,
    /// but only within text content (not leading indentation).
    private static func collapseSpaces(_ text: String) -> String {
        // Process line by line to preserve intentional leading indentation
        let lines = text.components(separatedBy: "\n")
        return lines.map { line in
            guard let firstNonSpace = line.firstIndex(where: { $0 != " " }) else {
                return line // all spaces or empty
            }
            let indent = line[line.startIndex..<firstNonSpace]
            let content = line[firstNonSpace...]
            let collapsed = collapseInlineSpaces(String(content))
            return indent + collapsed
        }.joined(separator: "\n")
    }

    /// Replaces runs of 2+ spaces with a single space within a string.
    private static func collapseInlineSpaces(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var prevWasSpace = false
        for char in text {
            if char == " " {
                if !prevWasSpace {
                    result.append(char)
                }
                prevWasSpace = true
            } else {
                result.append(char)
                prevWasSpace = false
            }
        }
        return result
    }
}
