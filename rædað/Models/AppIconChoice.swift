import Foundation

#if os(iOS)
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
