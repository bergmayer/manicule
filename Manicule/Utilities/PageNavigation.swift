import Foundation

/// Deterministic page/spread arithmetic shared by PDF and comic readers.
/// A two-page position always identifies the first page in its spread.
enum PageNavigation {
    nonisolated static func requestedIndex(_ text: String, pageCount: Int) -> Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              number >= 1, number <= pageCount else { return nil }
        return number - 1
    }

    /// Visit the visible page first, then neighbors, preferring the next page
    /// at equal distance. Each page appears exactly once, with no set needed.
    nonisolated static func nearestFirst(center: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let center = normalizedStart(current: center, pageCount: pageCount, twoUp: false)
        var pages = [center]
        for distance in 1..<pageCount {
            if center + distance < pageCount { pages.append(center + distance) }
            if center - distance >= 0 { pages.append(center - distance) }
        }
        return pages
    }

    nonisolated static func normalizedStart(current: Int, pageCount: Int, twoUp: Bool, coverOnRight: Bool = false) -> Int {
        guard pageCount > 0 else { return 0 }
        let clamped = min(max(current, 0), pageCount - 1)
        guard twoUp else { return clamped }
        if coverOnRight { return clamped == 0 ? 0 : clamped - (clamped - 1) % 2 }
        return clamped - clamped % 2
    }

    nonisolated static func previous(current: Int, pageCount: Int, twoUp: Bool, coverOnRight: Bool = false) -> Int {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp, coverOnRight: coverOnRight)
        return max(0, start - (twoUp ? 2 : 1))
    }

    nonisolated static func next(current: Int, pageCount: Int, twoUp: Bool, coverOnRight: Bool = false) -> Int {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp, coverOnRight: coverOnRight)
        let candidate = start + (twoUp && !(coverOnRight && start == 0) ? 2 : 1)
        return candidate < pageCount ? candidate : start
    }

    /// Ordinals let the native pager treat a cover and a full spread as equal turns.
    nonisolated static func spreadIndex(page: Int, coverOnRight: Bool) -> Int {
        coverOnRight ? (max(0, page) + 1) / 2 : max(0, page) / 2
    }

    nonisolated static func spreadStart(index: Int, coverOnRight: Bool) -> Int {
        coverOnRight ? max(0, index * 2 - 1) : max(0, index * 2)
    }

    nonisolated static func spreadCount(pageCount: Int, coverOnRight: Bool) -> Int {
        guard pageCount > 0 else { return 0 }
        return coverOnRight ? 1 + pageCount / 2 : (pageCount + 1) / 2
    }

    nonisolated static func canGoPrevious(current: Int, pageCount: Int, twoUp: Bool, coverOnRight: Bool = false) -> Bool {
        normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp, coverOnRight: coverOnRight) > 0
    }

    nonisolated static func canGoNext(current: Int, pageCount: Int, twoUp: Bool, coverOnRight: Bool = false) -> Bool {
        let start = normalizedStart(current: current, pageCount: pageCount, twoUp: twoUp, coverOnRight: coverOnRight)
        return next(current: start, pageCount: pageCount, twoUp: twoUp, coverOnRight: coverOnRight) != start
    }
}
