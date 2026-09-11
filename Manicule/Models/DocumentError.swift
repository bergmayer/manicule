import Foundation

enum DocumentError: Error, LocalizedError {
    case differentDocument
    case unreadable
    case notWritable
    case unsupportedType
    case parsingFailed(String)
    case zipExtractionFailed

    var errorDescription: String? {
        switch self {
        case .differentDocument: return "This is not the saved book, or its contents have changed. Locate the original file, or open the changed file directly from the document picker."
        case .unreadable: return "The file could not be read."
        case .notWritable: return "This app does not modify files."
        case .unsupportedType: return "This file type is not supported."
        case .parsingFailed(let detail): return "Parsing failed: \(detail)"
        case .zipExtractionFailed: return "Failed to extract archive."
        }
    }
}
