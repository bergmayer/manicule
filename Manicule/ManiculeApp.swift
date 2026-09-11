//
//  ManiculeApp.swift
//  Manicule
//
//  Created by John Bergmayer on 2/24/26.
//

import SwiftUI

@main
struct ManiculeApp: App {
    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            IOSRootView()
                .preferenceErrorAlert()
        }
        .commands {
            ReaderMenuCommands()
        }
        #else
        DocumentGroup(viewing: ReaderDocument.self) { configuration in
            DocumentViewer(
                document: configuration.document,
                fileURL: configuration.fileURL
            )
            .preferenceErrorAlert()
        }
        .defaultSize(width: 800, height: 1000)
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
        .commands {
            ReaderMenuCommands()
        }

        #if os(macOS)
        Settings {
            TabView {
                ReadingSettingsView(fileHash: nil)
                    .tabItem { Label("Reading", systemImage: "textformat.size") }
                NavigationStack {
                    PerBookSettingsView()
                }
                    .tabItem { Label("Books", systemImage: "books.vertical") }
            }
            .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, minHeight: 600)
            .preferenceErrorAlert()
        }
        #endif
        #endif
    }
}
