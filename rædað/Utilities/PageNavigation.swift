import Foundation

/// Deterministic page/spread arithmetic shared by PDF and comic readers.
/// A two-page position always identifies the first page in its spread.
enum PageNavigation {
    static func normalizedStart(current: Int, pageCount: Int, twoUp: Bool) -> Int {
        guard pageCount > 0 else { return 0 }
        let clamped = min(max(current, 0), pageCount - 1)
        return twoUp ? clamped - clamped % 2 : clamped
    }

    static func previous(current: Int, pageCount: Int, twoUp: Bool) -> Int {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp)
        return max(0, start - (twoUp ? 2 : 1))
    }

    static func next(current: Int, pageCount: Int, twoUp: Bool) -> Int {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp)
        let candidate = start + (twoUp ? 2 : 1)
        return candidate < pageCount ? candidate : start
    }

    static func canGoPrevious(current: Int, pageCount: Int, twoUp: Bool) -> Bool {
        normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp) > 0
    }

    static func canGoNext(current: Int, pageCount: Int, twoUp: Bool) -> Bool {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp)
        return start + (twoUp ? 2 : 1) < pageCount
    }
}
