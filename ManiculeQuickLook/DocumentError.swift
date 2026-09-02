import Foundation

/// Shared error type used by the ePub parser.
enum DocumentError: Error, LocalizedError {
    case parsingFailed(String)
    case zipExtractionFailed
    case noImagesFound

    var errorDescription: String? {
        switch self {
        case .parsingFailed(let detail): return "Parsing failed: \(detail)"
        case .zipExtractionFailed: return "Failed to extract archive."
        case .noImagesFound: return "No images found in comic archive."
        }
    }
}
