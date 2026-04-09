//
//  ZappaStreamApp.swift
//  ZappaStream
//
//  Created by Datisit on 02/02/2026.
//

import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

@main
struct ZappaStreamApp: App {
    @AppStorage("textScale") private var textScale: Double = 1.1

// Text scale levels: Smaller, Default, Large, Largest
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2, 1.3]

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([SavedShow.self])
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("ZappaStream", isDirectory: true)
        let storeURL = storeDir.appendingPathComponent("ZappaStream.store")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Schema migration failure — back up the broken store and start fresh
            print("⚠️ SwiftData store migration failed: \(error). Backing up and recreating.")
            let backupURL = storeDir.appendingPathComponent("ZappaStream.store.bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: storeURL, to: backupURL)
            let freshConfig = ModelConfiguration(schema: schema, url: storeURL)
            return (try? ModelContainer(for: schema, configurations: [freshConfig]))
                ?? { fatalError("Could not create ModelContainer even after reset: \(error)") }()
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
            CommandMenu("Audio") {
                Button("Volume Up") {
                    NotificationCenter.default.post(name: .volumeUp, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command, .shift])

                Button("Volume Down") {
                    NotificationCenter.default.post(name: .volumeDown, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Divider()

                Button("Smaller") {
                    decreaseTextScale()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textScale <= textScaleLevels.first!)

                Button("Default") {
                    textScale = 1.1
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Large") {
                    increaseTextScale()
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(textScale >= textScaleLevels.last!)

                Button("Largest") {
                    textScale = 1.3
                }
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
/// Notification names for menubar updates
extension Notification.Name {
    static let trackInfoUpdated = Notification.Name("trackInfoUpdated")
    static let playbackStateChanged = Notification.Name("playbackStateChanged")
    static let streamSelectionChanged = Notification.Name("streamSelectionChanged")
    static let togglePlayback = Notification.Name("togglePlayback")
    static let stopPlayback = Notification.Name("stopPlayback")
    static let selectStream = Notification.Name("selectStream")
    static let volumeUp = Notification.Name("volumeUp")
    static let volumeDown = Notification.Name("volumeDown")
    static let setVolume = Notification.Name("setVolume")
}

private class VolumeSliderView: NSView {
    private let slider: NSSlider

    init() {
        slider = NSSlider()
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))

        let currentVolume = UserDefaults.standard.object(forKey: "masterVolume") != nil
            ? UserDefaults.standard.float(forKey: "masterVolume") : 1.0

        let icon = NSImageView(frame: NSRect(x: 10, y: 8, width: 14, height: 14))
        icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        slider.frame = NSRect(x: 30, y: 7, width: 158, height: 16)
        slider.minValue = 0.0
        slider.maxValue = 1.0
        slider.doubleValue = Double(currentVolume)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged() {
        NotificationCenter.default.post(
            name: .setVolume,
            object: nil,
            userInfo: ["volume": Float(slider.doubleValue)]
        )
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2, 1.3]

    // Current state for menu
    private var currentTrackName: String?
    private var currentArtist: String?
    private var currentShowInfo: String?
    private var isPlaying: Bool = false
    private var selectedStreamFormat: String {
        get {
            let format = UserDefaults.standard.string(forKey: "lastStreamFormat") ?? "MP3"
            return format
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "lastStreamFormat")
        }
    }

    // Available streams (must match ContentView)
    private let streamFormats = ["MP3", "AAC", "OGG", "FLAC"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenubarIcon()
        setupStatusMenu()
        setupObservers()
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
        menu.delegate = self
        statusMenu = menu
    }

    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        // Now Playing info (if available)
        if currentTrackName != nil || currentShowInfo != nil {
            if let track = currentTrackName, !track.isEmpty {
                let trackItem = NSMenuItem(title: track, action: nil, keyEquivalent: "")
                trackItem.isEnabled = false
                menu.addItem(trackItem)
            }
            if let artist = currentArtist, !artist.isEmpty {
                let artistItem = NSMenuItem(title: artist, action: nil, keyEquivalent: "")
                artistItem.isEnabled = false
                artistItem.attributedTitle = NSAttributedString(
                    string: artist,
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]
                )
                menu.addItem(artistItem)
            }
            if let show = currentShowInfo, !show.isEmpty {
                let showItem = NSMenuItem(title: show, action: nil, keyEquivalent: "")
                showItem.isEnabled = false
                showItem.attributedTitle = NSAttributedString(
                    string: show,
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]
                )
                menu.addItem(showItem)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Play/Pause button
        let playPauseTitle = isPlaying ? "Pause" : "Play"
        let playPauseItem = NSMenuItem(title: playPauseTitle, action: #selector(togglePlayPause), keyEquivalent: "")
        menu.addItem(playPauseItem)

        // Stop button
        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopPlayback), keyEquivalent: "")
        stopItem.isEnabled = isPlaying
        menu.addItem(stopItem)

        // Stream picker submenu
        let streamItem = NSMenuItem(title: "Stream", action: nil, keyEquivalent: "")
        let streamSubmenu = NSMenu()

        for format in streamFormats {
            let formatItem = NSMenuItem(title: format, action: #selector(selectStreamFormat(_:)), keyEquivalent: "")
            formatItem.representedObject = format
            formatItem.state = (format == selectedStreamFormat) ? .on : .off
            streamSubmenu.addItem(formatItem)
        }

        streamItem.submenu = streamSubmenu
        menu.addItem(streamItem)

        menu.addItem(NSMenuItem.separator())

        // Audio submenu
        let audioItem = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        let audioSubmenu = NSMenu()

        let sliderItem = NSMenuItem()
        sliderItem.view = VolumeSliderView()
        audioSubmenu.addItem(sliderItem)

        audioSubmenu.addItem(NSMenuItem.separator())

        let volUpItem = NSMenuItem(title: "Volume Up", action: #selector(handleVolumeUp), keyEquivalent: "=")
        volUpItem.keyEquivalentModifierMask = [.command, .shift]
        audioSubmenu.addItem(volUpItem)

        let volDownItem = NSMenuItem(title: "Volume Down", action: #selector(handleVolumeDown), keyEquivalent: "-")
        volDownItem.keyEquivalentModifierMask = [.command, .shift]
        audioSubmenu.addItem(volDownItem)

        audioItem.submenu = audioSubmenu
        menu.addItem(audioItem)

        menu.addItem(NSMenuItem.separator())

        // Text Size submenu
        let textSizeItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let textSizeSubmenu = NSMenu()

        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(smallerText), keyEquivalent: "-")
        smallerItem.keyEquivalentModifierMask = .command
        textSizeSubmenu.addItem(smallerItem)

        let defaultItem = NSMenuItem(title: "Default", action: #selector(defaultTextSize), keyEquivalent: "0")
        defaultItem.keyEquivalentModifierMask = .command
        textSizeSubmenu.addItem(defaultItem)

        let largeItem = NSMenuItem(title: "Large", action: #selector(largeText), keyEquivalent: "")
        textSizeSubmenu.addItem(largeItem)

        let largestItem = NSMenuItem(title: "Largest", action: #selector(largestText), keyEquivalent: "")
        textSizeSubmenu.addItem(largestItem)

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
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTrackInfoUpdate(_:)),
            name: .trackInfoUpdated,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStateChanged(_:)),
            name: .playbackStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStreamSelectionChanged(_:)),
            name: .streamSelectionChanged,
            object: nil
        )
    }

    @objc private func handleTrackInfoUpdate(_ notification: Notification) {
        let userInfo = notification.userInfo

        currentTrackName = userInfo?["trackName"] as? String
        currentArtist = userInfo?["artist"] as? String
        currentShowInfo = userInfo?["showInfo"] as? String

        var tooltipLines: [String] = []

        // Mirror track info card - show info regardless of playing state
        if let track = currentTrackName, !track.isEmpty {
            tooltipLines.append(track)
        }
        if let artist = currentArtist, !artist.isEmpty {
            tooltipLines.append(artist)
        }
        if let show = currentShowInfo, !show.isEmpty {
            tooltipLines.append(show)
        }

        let newTooltip = tooltipLines.isEmpty ? "ZappaStream" : tooltipLines.joined(separator: "\n")
        print("📻 Menubar tooltip update: \(newTooltip)")
        statusItem?.button?.toolTip = newTooltip
    }

    @objc private func handlePlaybackStateChanged(_ notification: Notification) {
        if let playing = notification.userInfo?["isPlaying"] as? Bool {
            isPlaying = playing
            print("📻 Menubar playback state: \(isPlaying ? "playing" : "paused")")
        }
    }

    @objc private func handleStreamSelectionChanged(_ notification: Notification) {
        // Stream format is read directly from UserDefaults via the computed property
        // This notification is mainly for logging/debugging
        if let format = notification.userInfo?["format"] as? String {
            print("📻 Menubar stream selection: \(format)")
        }
    }

    @objc private func togglePlayPause() {
        NotificationCenter.default.post(name: .togglePlayback, object: nil)
    }

    @objc private func stopPlayback() {
        NotificationCenter.default.post(name: .stopPlayback, object: nil)
    }

    @objc private func selectStreamFormat(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String else { return }
        NotificationCenter.default.post(
            name: .selectStream,
            object: nil,
            userInfo: ["format": format]
        )
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
                // Window is visible and focused on current space — close it
                window.close()
            } else if window.isVisible && window.isOnActiveSpace {
                // Visible on current space but not focused — bring to front
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                // Window is on a different space (or hidden).
                // orderOut detaches it from its current space so that the
                // subsequent makeKeyAndOrderFront opens it on the active space
                // instead of causing macOS to switch spaces.
                if !window.isOnActiveSpace {
                    window.orderOut(nil)
                }
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

    @objc private func largeText() {
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

    @objc private func largestText() {
        UserDefaults.standard.set(1.3, forKey: "textScale")
    }

    // MARK: - Volume Actions

    @objc private func handleVolumeUp() {
        NotificationCenter.default.post(name: .volumeUp, object: nil)
    }

    @objc private func handleVolumeDown() {
        NotificationCenter.default.post(name: .volumeDown, object: nil)
    }

    @objc private func openSettings() {
        // Simulate the Cmd+, keyboard shortcut which is the standard way to open Settings
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint.zero,
            modifierFlags: .command,
            timestamp: NSDate().timeIntervalSince1970,
            windowNumber: 0,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 0x2B  // Key code for comma
        )

        if let event = keyEvent {
            NSApplication.shared.sendEvent(event)
        }
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
