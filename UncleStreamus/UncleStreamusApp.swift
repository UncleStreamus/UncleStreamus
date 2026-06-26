//
//  UncleStreamusApp.swift
//  UncleStreamus
//
//  Created by Darcy Taranto on 02/02/2026.
//

import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

@main
struct UncleStreamusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // History container: SavedShow only, separate from cache so Z_METADATA never contains cache entity hashes.
    // Both CloudKit-on and CloudKit-off configs use the same store file — data survives the sync toggle.
    var historyModelContainer: ModelContainer = {
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else {
            return try! ModelContainer(for: Schema([SavedShow.self]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        // One-time rebrand migration: bring the personal history store over from the
        // legacy ZappaStream app group before the store opens (no-op after the first run).
        StoreProtection.migrateFromLegacyGroup()

        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.unclestreamus.shared"
        ) else {
            fatalError("App Group container unavailable — check entitlements and Developer Portal configuration.")
        }
        let storeDir = groupContainer.appendingPathComponent("UncleStreamus", isDirectory: true)
        let historyStoreURL = storeDir.appendingPathComponent("UncleStreamus-history.store")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        // Pre-launch store protection: backup before CloudKit can wipe, and auto-restore
        // if CloudKit performed a zone-reset that emptied the store.
        if let backupURL = StoreProtection.backupURL {
            if UserDefaults.standard.bool(forKey: "pendingStoreRestoreFromBackup") {
                UserDefaults.standard.removeObject(forKey: "pendingStoreRestoreFromBackup")
                StoreProtection.restoreAndClearMetadata(from: backupURL, to: historyStoreURL)
                #if DEBUG
                print("🔄 Applied pending restore from backup")
                #endif
            } else {
                let count = StoreProtection.countRecords(at: historyStoreURL)
                if count > 0 {
                    StoreProtection.backup(from: historyStoreURL, to: backupURL)
                } else if count == 0 {
                    let backupCount = StoreProtection.countRecords(at: backupURL)
                    if backupCount > 0 {
                        StoreProtection.restoreAndClearMetadata(from: backupURL, to: historyStoreURL)
                        #if DEBUG
                        print("🛡️ Auto-restored \(backupCount) records from backup (store was empty)")
                        #endif
                    }
                }
            }
        }

        // NOTE: The app never mutates the CloudKit zone or subscriptions itself — that lifecycle
        // is owned entirely by NSPersistentCloudKitContainer. (A previous homegrown zone-reset ran
        // on every device including empty ones and deleted the shared zone, wiping synced data.)
        // The only protection here is the local backup/auto-restore above, which never deletes data.

        let iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        // UserDefaults.bool(forKey:) returns false for absent keys, but the intended default is
        // true (matching the @AppStorage default). The model container is created before any view
        // renders, so @AppStorage hasn't had a chance to write its default yet on a fresh install.
        let iCloudSyncPref = (UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool) ?? true
        let iCloudEnabled = iCloudSyncPref && iCloudAvailable
        #if DEBUG
        print("☁️ iCloudAvailable=\(iCloudAvailable) iCloudSyncEnabled=\(iCloudSyncPref) → cloudKit=\(iCloudEnabled ? "ON" : "OFF")")
        #endif

        let config = ModelConfiguration(
            schema: Schema([SavedShow.self]),
            url: historyStoreURL,
            cloudKitDatabase: iCloudEnabled
                ? .private("iCloud.com.unclestreamus.UncleStreamus")
                : .none
        )

        do {
            return try ModelContainer(for: Schema([SavedShow.self]), configurations: [config])
        } catch {
            // CloudKit config failed (e.g. entitlement misconfiguration) — fall back to local-only on the same
            // store file so existing data is preserved.
            #if DEBUG
            print("⚠️ History store failed (\(error)) — retrying without CloudKit")
            #endif
            let fallback = ModelConfiguration(schema: Schema([SavedShow.self]), url: historyStoreURL, cloudKitDatabase: .none)
            return (try? ModelContainer(for: Schema([SavedShow.self]), configurations: [fallback]))
                ?? { fatalError("Could not create history ModelContainer: \(error)") }()
        }
    }()

    // Cache container: CachedFZShow + FZShowsPageRecord, local only. Never synced to CloudKit.
    var cacheModelContainer: ModelContainer = {
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else {
            return try! ModelContainer(for: Schema([CachedFZShow.self, FZShowsPageRecord.self]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.unclestreamus.shared"
        ) else { fatalError("App Group container unavailable.") }
        let storeDir = groupContainer.appendingPathComponent("UncleStreamus", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let config = ModelConfiguration(
            schema: Schema([CachedFZShow.self, FZShowsPageRecord.self]),
            url: storeDir.appendingPathComponent("UncleStreamusCache.store"),
            cloudKitDatabase: .none
        )
        return (try? ModelContainer(for: Schema([CachedFZShow.self, FZShowsPageRecord.self]), configurations: [config]))
            ?? { fatalError("Could not create cache ModelContainer") }()
    }()

    init() {
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
            PerShowFXSync.start()
        }
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "delayWarningDismissed")
        #endif
    }

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
                .environment(\.cacheModelContainer, cacheModelContainer)
        }
        .modelContainer(historyModelContainer)
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

    @SceneBuilder
    private var macOSScene: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(\.cacheModelContainer, cacheModelContainer)
        }
        .modelContainer(historyModelContainer)
        .defaultSize(width: 350, height: 520)
        .commands {
            CommandMenu("Audio") {
                Button("Volume Up") {
                    appDelegate.bassPlayer?.volumeUp()
                }
                .keyboardShortcut("=", modifiers: [.command, .shift])

                Button("Volume Down") {
                    appDelegate.bassPlayer?.volumeDown()
                }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            }

            // Owns its own @AppStorage("textScale") so a text-size change invalidates only
            // these commands — not the App body / WindowGroup content. Re-evaluating the
            // WindowGroup content would re-run `ContentView()`'s `@State = BASSRadioPlayer()`
            // initializer, constructing (and immediately deallocating) a throwaway player on
            // every scale change.
            TextSizeCommands()
        }

        Settings {
            SettingsView()
                .modelContainer(historyModelContainer)
                .environment(\.cacheModelContainer, cacheModelContainer)
        }
    }
    #endif

}

#if os(macOS)
/// macOS text-size menu commands (Smaller / Default / Large / Largest).
///
/// This lives in its own `Commands` type — rather than inline in `UncleStreamusApp.body` —
/// so that owning `@AppStorage("textScale")` here means a text-size change invalidates only
/// these commands. If the App struct read `textScale`, every change would re-evaluate the
/// App body and re-run the `WindowGroup { ContentView() }` content closure, which
/// reconstructs (and immediately deallocates) a throwaway `BASSRadioPlayer` via
/// `ContentView`'s `@State private var bassPlayer = BASSRadioPlayer()`.
struct TextSizeCommands: Commands {
    @AppStorage("textScale") private var textScale: Double = 1.1

    // Text scale levels: Smaller, Default, Large, Largest
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2, 1.3]

    var body: some Commands {
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
#endif

// MARK: - macOS App Delegate for Menubar

#if os(macOS)
private class VolumeSliderView: NSView {
    private let slider: NSSlider

    /// Set by `rebuildMenu` to forward slider changes to the player. Replaces the
    /// old `.setVolume` NotificationCenter post.
    var onVolumeChange: ((Float) -> Void)?

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
        onVolumeChange?(Float(slider.doubleValue))
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// The single instance created by `@NSApplicationDelegateAdaptor`. SwiftUI sets
    /// its *own* `SwiftUI.AppDelegate` as `NSApp.delegate` and merely *wraps* this
    /// one, so `NSApp.delegate as? AppDelegate` is always nil — views reach the
    /// real delegate through this instead.
    static private(set) var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let textScaleLevels: [Double] = [1.0, 1.1, 1.2, 1.3]

    // Shared view state, set by ContentView.setupPlayer(). The menubar drives
    // playback and reads now-playing state through these instead of the old
    // NotificationCenter bridge; weak so a closing window doesn't keep them alive.
    weak var radioVM: RadioViewModel?
    weak var bassPlayer: BASSRadioPlayer?

    // Cached now-playing strings for the menu's Now Playing section, pushed from
    // ContentView via updateNowPlaying(_:).
    private var currentTrackName: String?
    private var currentArtist: String?
    private var currentShowInfo: String?
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
    private let streamFormats = ["MP3", "OGG", "AAC", "FLAC"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
        setupMenubarIcon()
        setupStatusMenu()
    }

    private func setupMenubarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Use SF Symbol for the menubar icon
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let image = NSImage(systemSymbolName: "radio", accessibilityDescription: "UncleStreamus") {
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
            button.toolTip = "UncleStreamus"
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

        let isPlaying = radioVM?.isPlaying ?? false

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
        let sliderView = VolumeSliderView()
        sliderView.onVolumeChange = { [weak self] volume in
            self?.bassPlayer?.setMasterVolume(volume)
        }
        sliderItem.view = sliderView
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

        // About submenu — Welcome guide + What's New sheets
        let aboutItem = NSMenuItem(title: "About", action: nil, keyEquivalent: "")
        let aboutSubmenu = NSMenu()
        aboutSubmenu.addItem(NSMenuItem(title: "Welcome to UncleStreamus", action: #selector(showWelcomeSheet), keyEquivalent: ""))
        aboutSubmenu.addItem(NSMenuItem(title: "What's New", action: #selector(showWhatsNewSheet), keyEquivalent: ""))
        aboutItem.submenu = aboutSubmenu
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit UncleStreamus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - View bridge

    /// Wired by `ContentView.setupPlayer()` so the menubar can drive playback and
    /// read now-playing state directly — replaces the old NotificationCenter
    /// command/state bridge.
    func attach(vm: RadioViewModel, bassPlayer: BASSRadioPlayer) {
        self.radioVM = vm
        self.bassPlayer = bassPlayer
    }

    func detach() {
        radioVM = nil
        bassPlayer = nil
    }

    /// Pushed from `ContentView` whenever now-playing changes: caches the strings
    /// the menu's Now Playing section renders and refreshes the icon tooltip.
    /// Replaces the old `.trackInfoUpdated` observer.
    func updateNowPlaying(trackName: String?, artist: String?, showInfo: String?) {
        currentTrackName = trackName
        currentArtist = artist
        currentShowInfo = showInfo

        var tooltipLines: [String] = []
        if let track = trackName, !track.isEmpty { tooltipLines.append(track) }
        if let artist, !artist.isEmpty { tooltipLines.append(artist) }
        if let show = showInfo, !show.isEmpty { tooltipLines.append(show) }

        let newTooltip = tooltipLines.isEmpty ? "UncleStreamus" : tooltipLines.joined(separator: "\n")
        #if DEBUG
        print("📻 Menubar tooltip update: \(newTooltip)")
        #endif
        statusItem?.button?.toolTip = newTooltip
    }

    @objc private func togglePlayPause() {
        radioVM?.menubarToggle()
    }

    @objc private func stopPlayback() {
        radioVM?.menubarStop()
    }

    @objc private func selectStreamFormat(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String else { return }
        radioVM?.menubarSelectStream(format)
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

    /// The SwiftUI `WindowGroup(id: "main")` content window. SwiftUI appends a
    /// suffix to the identifier (e.g. "main-AppWindow-1"), so match by prefix.
    /// Title fallback uses the runtime display name rather than a hardcoded brand
    /// string, so a rebrand can't silently break window detection again.
    private var mainWindow: NSWindow? {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return NSApplication.shared.windows.first {
            $0.identifier?.rawValue.hasPrefix("main") == true
                || ($0.title == displayName && !$0.title.isEmpty)
        }
    }

    private func toggleMainWindow() {
        if let window = mainWindow {
            // Ensure the window can move to the active space when shown, so
            // makeKeyAndOrderFront places it here rather than switching spaces.
            if !window.collectionBehavior.contains(.moveToActiveSpace) {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }

            if window.isVisible && window.isOnActiveSpace {
                // Window is visible on the current space — close it (toggle off).
                // Don't check isKeyWindow: clicking the status bar item shifts
                // focus away from the window, so isKeyWindow is unreliable here.
                window.close()
            } else {
                // Window is on a different space (or hidden). orderOut detaches
                // it from its current space; activate(false) brings the app
                // forward without triggering a space switch.
                if !window.isOnActiveSpace {
                    window.orderOut(nil)
                }
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: false)
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
        bassPlayer?.volumeUp()
    }

    @objc private func handleVolumeDown() {
        bassPlayer?.volumeDown()
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

    @objc private func showWelcomeSheet() {
        presentSheet { [weak self] in self?.radioVM?.menubarShowWelcome() }
    }

    @objc private func showWhatsNewSheet() {
        presentSheet { [weak self] in self?.radioVM?.menubarShowWhatsNew() }
    }

    /// Presents a sheet on the live `ContentView`. The sheet can only attach to an
    /// on-screen window, so ensure the main window is open first. When the window
    /// was closed it's freshly re-created, so delay the call long enough for
    /// `ContentView.onAppear`/`setupPlayer()` to re-attach the view model.
    private func presentSheet(_ present: @escaping () -> Void) {
        let window = mainWindow
        let alreadyVisible = (window?.isVisible == true) && (window?.isOnActiveSpace == true)

        if !alreadyVisible {
            showMainWindow()
        }

        let delay = alreadyVisible ? 0.0 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: present)
    }

    /// Brings the main window forward without toggling it closed (unlike
    /// `toggleMainWindow`, which hides an already-visible window).
    func showMainWindow() {
        if let window = mainWindow {
            if !window.collectionBehavior.contains(.moveToActiveSpace) {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
            if !window.isOnActiveSpace {
                window.orderOut(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: false)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
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
