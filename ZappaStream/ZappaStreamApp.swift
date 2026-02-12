//
//  ZappaStreamApp.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 02/02/2026.
//

import SwiftUI
import SwiftData

@main
struct ZappaStreamApp: App {
    @AppStorage("textScale") private var textScale: Double = 1.1

    // Text scale levels: Small, Default, Large
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2]

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SavedShow.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        #if os(macOS)
        macOSScene
        #else
        iOSScene
        #endif
    }

    // MARK: - iOS Scene

    #if os(iOS)
    private var iOSScene: some Scene {
        WindowGroup {
            ContentView_iOS()
        }
        .modelContainer(sharedModelContainer)
    }
    #endif

    // MARK: - macOS Scene

    #if os(macOS)
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = false
    @AppStorage("showInfoExpanded") private var showInfoExpanded: Bool = false

    private let mainContentMinWidth: CGFloat = 350
    private let sidebarWidth: CGFloat = 280
    private let dividerWidth: CGFloat = 1

    private var minWindowWidth: CGFloat {
        isSidebarVisible ? mainContentMinWidth + sidebarWidth + dividerWidth : mainContentMinWidth
    }

    private var maxWindowWidth: CGFloat {
        isSidebarVisible ? 900 : 900 - sidebarWidth - dividerWidth
    }

    private var minWindowHeight: CGFloat {
        if showInfoExpanded {
            let baseHeight: CGFloat = 520
            let scaleBonus = (textScale - 1.0) * 500
            return baseHeight + scaleBonus
        } else {
            return 380
        }
    }

    @SceneBuilder
    private var macOSScene: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 350, height: 520)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Smaller Text") {
                    decreaseTextScale()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textScale <= textScaleLevels.first!)

                Button("Default Text Size") {
                    textScale = 1.1
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Larger Text") {
                    increaseTextScale()
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(textScale >= textScaleLevels.last!)
            }
        }

        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
        }
    }
    #endif

    // MARK: - Text Scale Helpers

    private func increaseTextScale() {
        if let currentIndex = textScaleLevels.firstIndex(of: textScale),
           currentIndex < textScaleLevels.count - 1 {
            textScale = textScaleLevels[currentIndex + 1]
        } else if textScale < textScaleLevels.last! {
            textScale = textScaleLevels.first { $0 > textScale } ?? textScaleLevels.last!
        }
    }

    private func decreaseTextScale() {
        if let currentIndex = textScaleLevels.firstIndex(of: textScale),
           currentIndex > 0 {
            textScale = textScaleLevels[currentIndex - 1]
        } else if textScale > textScaleLevels.first! {
            textScale = textScaleLevels.last { $0 < textScale } ?? textScaleLevels.first!
        }
    }
}
