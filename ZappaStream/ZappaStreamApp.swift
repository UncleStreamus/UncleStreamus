//
//  ZappaStreamApp.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 02/02/2026.
//

import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

@main
struct ZappaStreamApp: App {
    @AppStorage("textScale") private var textScale: Double = 1.1

    // Text scale levels: Small, Default, Large
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2]

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

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

// MARK: - macOS App Delegate for Menubar

#if os(macOS)
/// Notification name for track info updates
extension Notification.Name {
    static let trackInfoUpdated = Notification.Name("trackInfoUpdated")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenubarIcon()
        setupStatusMenu()
        setupTrackInfoObserver()
    }

    private func setupMenubarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Use SF Symbol for the menubar icon
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let image = NSImage(systemSymbolName: "radio", accessibilityDescription: "ZappaStream") {
                image.isTemplate = true  // Allows proper dark/light mode adaptation
                if let configuredImage = image.withSymbolConfiguration(config) {
                    // Create a new image with adjusted alignment to center vertically
                    let centeredImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                        let imageSize = configuredImage.size
                        let x = (rect.width - imageSize.width) / 2
                        let y = (rect.height - imageSize.height) / 2
                        configuredImage.draw(in: NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height))
                        return true
                    }
                    centeredImage.isTemplate = true
                    button.image = centeredImage
                }
            }
            button.action = #selector(menubarIconClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.toolTip = "ZappaStream"
        }
    }

    private func setupStatusMenu() {
        let menu = NSMenu()

        // Text Size submenu
        let textSizeItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let textSizeSubmenu = NSMenu()

        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(smallerText), keyEquivalent: "-")
        smallerItem.keyEquivalentModifierMask = .command
        textSizeSubmenu.addItem(smallerItem)

        let defaultItem = NSMenuItem(title: "Default", action: #selector(defaultTextSize), keyEquivalent: "0")
        defaultItem.keyEquivalentModifierMask = .command
        textSizeSubmenu.addItem(defaultItem)

        let largerItem = NSMenuItem(title: "Larger", action: #selector(largerText), keyEquivalent: "=")
        largerItem.keyEquivalentModifierMask = .command
        textSizeSubmenu.addItem(largerItem)

        textSizeItem.submenu = textSizeSubmenu
        menu.addItem(textSizeItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit ZappaStream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        statusMenu = menu
    }

    private func setupTrackInfoObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTrackInfoUpdate(_:)),
            name: .trackInfoUpdated,
            object: nil
        )
    }

    @objc private func handleTrackInfoUpdate(_ notification: Notification) {
        let userInfo = notification.userInfo

        let trackName = userInfo?["trackName"] as? String
        let artist = userInfo?["artist"] as? String
        let showInfo = userInfo?["showInfo"] as? String

        var tooltipLines: [String] = []

        // Mirror track info card - show info regardless of playing state
        if let track = trackName, !track.isEmpty {
            tooltipLines.append(track)
        }
        if let artist = artist, !artist.isEmpty {
            tooltipLines.append(artist)
        }
        if let show = showInfo, !show.isEmpty {
            tooltipLines.append(show)
        }

        let newTooltip = tooltipLines.isEmpty ? "ZappaStream" : tooltipLines.joined(separator: "\n")
        print("📻 Menubar tooltip update: \(newTooltip)")
        statusItem?.button?.toolTip = newTooltip
    }

    @objc private func menubarIconClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show context menu
            if let menu = statusMenu {
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil)
                statusItem?.menu = nil  // Remove menu so left-click works normally
            }
        } else {
            // Left-click: toggle window
            toggleMainWindow()
        }
    }

    private func toggleMainWindow() {
        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title.contains("Zappa")
        }) {
            if window.isVisible && window.isKeyWindow {
                // Window is visible and focused - close it
                window.close()
            } else if window.isVisible {
                // Window is visible but not focused - bring to front
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                // Window exists but is hidden - show it
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        } else {
            // No window exists - create one by activating the app
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Text Size Actions

    @objc private func smallerText() {
        let currentScale = UserDefaults.standard.double(forKey: "textScale")
        let scale = currentScale == 0 ? 1.1 : currentScale  // Default if not set
        if let currentIndex = textScaleLevels.firstIndex(of: scale), currentIndex > 0 {
            UserDefaults.standard.set(textScaleLevels[currentIndex - 1], forKey: "textScale")
        } else if scale > textScaleLevels.first! {
            if let newScale = textScaleLevels.last(where: { $0 < scale }) {
                UserDefaults.standard.set(newScale, forKey: "textScale")
            }
        }
    }

    @objc private func defaultTextSize() {
        UserDefaults.standard.set(1.1, forKey: "textScale")
    }

    @objc private func largerText() {
        let currentScale = UserDefaults.standard.double(forKey: "textScale")
        let scale = currentScale == 0 ? 1.1 : currentScale  // Default if not set
        if let currentIndex = textScaleLevels.firstIndex(of: scale), currentIndex < textScaleLevels.count - 1 {
            UserDefaults.standard.set(textScaleLevels[currentIndex + 1], forKey: "textScale")
        } else if scale < textScaleLevels.last! {
            if let newScale = textScaleLevels.first(where: { $0 > scale }) {
                UserDefaults.standard.set(newScale, forKey: "textScale")
            }
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When reopening the app, show the window
        if !flag {
            toggleMainWindow()
        }
        return true
    }
}
#endif
