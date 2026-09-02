import SwiftUI

/// Menu bar commands for macOS and iPad with keyboard.
/// Uses NotificationCenter to communicate with active reader views.
struct ReaderMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                Button("Add Bookmark") {
                    NotificationCenter.default.post(name: .bookmarkPosition, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Go to Bookmark...") {
                    NotificationCenter.default.post(name: .showSavedPositions, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button("Table of Contents") {
                    NotificationCenter.default.post(name: .toggleTableOfContents, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Go to Page...") {
                    NotificationCenter.default.post(name: .showGoToPage, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command])

                Button("Reading Settings...") {
                    NotificationCenter.default.post(name: .showReadingSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])

                Button("Toggle View Mode") {
                    NotificationCenter.default.post(name: .toggleViewMode, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("Toggle Reading Direction") {
                    NotificationCenter.default.post(name: .toggleReadingDirection, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Toggle Immersive Reading") {
                    NotificationCenter.default.post(name: .toggleImmersive, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Next Chapter") {
                    NotificationCenter.default.post(name: .nextChapter, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Chapter") {
                    NotificationCenter.default.post(name: .previousChapter, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Find...") {
                    NotificationCenter.default.post(name: .toggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                #if os(iOS) || os(visionOS)
                Button("Read Aloud") {
                    NotificationCenter.default.post(name: .toggleReadAloud, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                #endif

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
            }
        }
    }
}

// MARK: - Notification Names for Menu Commands

extension Notification.Name {
    static let bookmarkPosition = Notification.Name("manicule.bookmark")
    static let toggleTableOfContents = Notification.Name("manicule.toggleTOC")
    static let showGoToPage = Notification.Name("manicule.goToPage")
    static let showReadingSettings = Notification.Name("manicule.readingSettings")
    static let toggleViewMode = Notification.Name("manicule.toggleViewMode")
    static let zoomIn = Notification.Name("manicule.zoomIn")
    static let zoomOut = Notification.Name("manicule.zoomOut")
    static let toggleReadingDirection = Notification.Name("manicule.toggleReadingDirection")
    static let toggleImmersive = Notification.Name("manicule.toggleImmersive")
    static let showSavedPositions = Notification.Name("manicule.showSavedPositions")
    static let nextChapter = Notification.Name("manicule.nextChapter")
    static let previousChapter = Notification.Name("manicule.previousChapter")
    static let openFromQLPreview = Notification.Name("manicule.openFromQLPreview")
    static let toggleSearch = Notification.Name("manicule.toggleSearch")
    static let toggleReadAloud = Notification.Name("manicule.toggleReadAloud")
}
