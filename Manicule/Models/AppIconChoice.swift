import Foundation

#if os(iOS)
import Observation
import UIKit
#endif

/// The colorways shared by Manicule and Pilcrow.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case forest
    case burgundy
    case indigo
    case ochre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forest: "Forest"
        case .burgundy: "Burgundy"
        case .indigo: "Indigo"
        case .ochre: "Ochre"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .forest: nil
        case .burgundy: "AppIconBurgundy"
        case .indigo: "AppIconIndigo"
        case .ochre: "AppIconOchre"
        }
    }

    /// Normal image assets also let the library and settings show the chosen icon.
    var imageName: String {
        switch self {
        case .forest: "LaunchBackground"
        case .burgundy: "IconBurgundy"
        case .indigo: "IconIndigo"
        case .ochre: "IconOchre"
        }
    }

    @MainActor
    static var current: AppIconChoice {
        #if os(iOS)
        switch UIApplication.shared.alternateIconName {
        case "AppIconBurgundy": .burgundy
        case "AppIconIndigo": .indigo
        case "AppIconOchre": .ochre
        default: .forest
        }
        #else
        .forest
        #endif
    }
}

#if os(iOS)
/// One icon change at a time, shared by every settings sheet and library window.
@MainActor
@Observable
final class AppIconStore {
    static let shared = AppIconStore(
        currentChoice: .current,
        supportsAlternateIcons: UIApplication.shared.supportsAlternateIcons,
        setIcon: { try await UIApplication.shared.setAlternateIconName($0) }
    )

    private(set) var choice: AppIconChoice
    private(set) var changingTo: AppIconChoice?
    let supportsAlternateIcons: Bool
    private let setIcon: @MainActor (String?) async throws -> Void

    init(
        currentChoice: AppIconChoice,
        supportsAlternateIcons: Bool,
        setIcon: @escaping @MainActor (String?) async throws -> Void
    ) {
        choice = currentChoice
        self.supportsAlternateIcons = supportsAlternateIcons
        self.setIcon = setIcon
    }

    func refresh() {
        guard changingTo == nil else { return }
        choice = .current
    }

    func change(to requestedChoice: AppIconChoice) async throws {
        guard supportsAlternateIcons, changingTo == nil, requestedChoice != choice else { return }
        changingTo = requestedChoice
        defer { changingTo = nil }
        try await setIcon(requestedChoice.alternateIconName)
        choice = requestedChoice
    }
}
#endif
