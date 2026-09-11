import Foundation

enum TextDecoder {
    /// Decodes common text-file encodings without silently turning an
    /// unsupported or corrupt document into an empty book.
    nonisolated static func decode(_ data: Data) throws -> String {
        if data.isEmpty { return "" }

        var encodings: [String.Encoding] = [.utf8]
        let bytes = [UInt8](data.prefix(4_096))
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
            if let text = String(data: data, encoding: encoding), isPlausibleText(text) {
                return text
            }
        }
        throw DocumentError.parsingFailed("The text encoding is not supported or the file is not valid text.")
    }

    private nonisolated static func isPlausibleText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        var controls = 0
        var count = 0
        for scalar in text.unicodeScalars.prefix(4_096) {
            count += 1
            if scalar.value == 0
                || scalar.properties.generalCategory == .control
                    && scalar.value != 10 && scalar.value != 13 && scalar.value != 9 {
                controls += 1
            }
        }
        return count == 0 || Double(controls) / Double(count) < 0.05
    }

}
