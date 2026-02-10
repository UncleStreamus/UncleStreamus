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
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = false
    @AppStorage("textScale") private var textScale: Double = 1.1
    @AppStorage("showInfoExpanded") private var showInfoExpanded: Bool = false

    // Text scale levels: Small, Default, Large
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2]

    private let mainContentMinWidth: CGFloat = 350
    private let sidebarWidth: CGFloat = 280
    private let dividerWidth: CGFloat = 1

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

    private var minWindowWidth: CGFloat {
        isSidebarVisible ? mainContentMinWidth + sidebarWidth + dividerWidth : mainContentMinWidth
    }

    private var maxWindowWidth: CGFloat {
        isSidebarVisible ? 900 : 900 - sidebarWidth - dividerWidth
    }

    private var minWindowHeight: CGFloat {
        if showInfoExpanded {
            // Scale expanded height with text size: 520 at 1.0, 570 at 1.1, 620 at 1.2
            let baseHeight: CGFloat = 520
            let scaleBonus = (textScale - 1.0) * 500  // +50 per 0.1 scale increase
            return baseHeight + scaleBonus
        } else {
            return 380
        }
    }

    var body: some Scene {
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
        }
    }

    private func increaseTextScale() {
        if let currentIndex = textScaleLevels.firstIndex(of: textScale),
           currentIndex < textScaleLevels.count - 1 {
            textScale = textScaleLevels[currentIndex + 1]
        } else if textScale < textScaleLevels.last! {
            // Find the next level up
            textScale = textScaleLevels.first { $0 > textScale } ?? textScaleLevels.last!
        }
    }

    private func decreaseTextScale() {
        if let currentIndex = textScaleLevels.firstIndex(of: textScale),
           currentIndex > 0 {
            textScale = textScaleLevels[currentIndex - 1]
        } else if textScale > textScaleLevels.first! {
            // Find the next level down
            textScale = textScaleLevels.last { $0 < textScale } ?? textScaleLevels.first!
        }
    }
}
