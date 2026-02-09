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

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .frame(minWidth: minWindowWidth, maxWidth: 900, minHeight: 520, maxHeight: 800)
        }
        .modelContainer(sharedModelContainer)
        .windowResizability(.contentSize)
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
