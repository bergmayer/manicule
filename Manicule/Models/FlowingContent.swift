import Foundation

/// Input formats share one reader; only publication preparation differs.
nonisolated enum FlowingContent: Sendable {
    case epub(EPubBook)
    case plain(String)
    case markdown(String)

    var text: String? {
        switch self {
        case .epub: nil
        case .plain(let value), .markdown(let value): value
        }
    }
    var isMarkdown: Bool {
        if case .markdown = self { return true }
        return false
    }
}
