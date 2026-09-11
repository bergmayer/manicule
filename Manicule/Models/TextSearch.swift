import Foundation

nonisolated enum TextSearch {
    struct Match: Sendable {
        let range: NSRange
        let fraction: Double
        let chunk: Int
    }

    static func matches(in text: String, query: String) throws -> [Match] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var matches: [Match] = []
        var start = text.startIndex
        var offset = 0
        var line = 0
        let length = text.count
        while let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            try Task.checkCancellation()
            let preceding = text[start..<range.lowerBound]
            offset += preceding.count
            line += preceding.filter { $0 == "\n" }.count
            matches.append(Match(range: NSRange(range, in: text), fraction: Double(offset) / Double(length), chunk: line / 100))
            offset += text[range].count
            line += text[range].filter { $0 == "\n" }.count
            start = range.upperBound
        }
        try Task.checkCancellation()
        return matches
    }
}
