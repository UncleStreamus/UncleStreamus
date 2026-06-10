//
//  SettingsView.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 10/02/2026.
//

import SwiftUI
import SwiftData

private struct TabContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .playback
    #if os(macOS)
    @State private var tabContentHeight: CGFloat = 500
    @State private var hasInitialTabHeight = false
    #endif

    enum SettingsTab {
        case playback, sync, savedData, credits
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .playback: PlaybackSettingsView()
        case .sync: SyncSettingsView()
        case .savedData: SavedDataSettingsView()
        case .credits: CreditsView()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Playback").tag(SettingsTab.playback)
                Text("Sync").tag(SettingsTab.sync)
                Text("Data").tag(SettingsTab.savedData)
                Text("Credits").tag(SettingsTab.credits)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            #if os(iOS)
            ScrollView {
                tabContent
            }
            #else
            tabContent
                .animation(nil, value: selectedTab)
                .frame(height: tabContentHeight)
                .background(
                    tabContent
                        .frame(width: 400)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TabContentHeightKey.self,
                                value: geo.size.height
                            )
                        })
                )
            #endif
        }
        #if os(macOS)
        .frame(width: 400)
        .onPreferenceChange(TabContentHeightKey.self) { newHeight in
            guard newHeight > 0 else { return }
            if hasInitialTabHeight {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    tabContentHeight = newHeight
                }
            } else {
                tabContentHeight = newHeight
                hasInitialTabHeight = true
            }
        }
        #endif
        .navigationTitle("Settings")
    }
}

// MARK: - Settings Section Header

struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

// MARK: - Settings Section Box

struct SettingsSectionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.controlBackground)
        .cornerRadius(8)
        .padding(.horizontal, 20)
    }
}

// MARK: - Playback Settings

struct PlaybackSettingsView: View {
    @AppStorage("autoResumeOnLaunch") private var autoResumeOnLaunch: Bool = false
    @AppStorage("fxRememberPerShow") private var fxRememberPerShow: Bool = true
    @AppStorage("fxPersistAcrossShows") private var fxPersistAcrossShows: Bool = false
    @AppStorage("dvrEnabled") private var dvrEnabled: Bool = true
    @AppStorage("dvrBufferMinutes") private var dvrBufferMinutes: Int = 15

    /// Disk space used by the DVR ring buffer for a given number of minutes.
    /// Buffer stores decoded 16-bit PCM at 44100 Hz stereo regardless of input format.
    private func dvrDiskSize(minutes: Int) -> String {
        let bytes = Double(minutes) * 60.0 * 44100 * 2 * 2   // samples/s × ch × bytes/sample
        let mb = bytes / (1024 * 1024)
        return "~\(Int(mb.rounded())) MB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Stream", systemImage: "play.circle")

            SettingsSectionBox {
                Toggle(isOn: $autoResumeOnLaunch) {
                    Text("Resume playback on launch")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Automatically continue playing when the app launches, if it was playing when you last quit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 4)

                Toggle(isOn: $dvrEnabled) {
                    Text("Continue buffering while paused")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Keep the stream buffering when paused so you can resume from where you left off.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Buffer window")
                        .font(.callout)
                    Spacer()
                    Text("\(dvrBufferMinutes) min")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(dvrEnabled ? .primary : .secondary)
                }
                .padding(.top, 4)

                Slider(
                    value: Binding(
                        get: { Double(dvrBufferMinutes) },
                        set: { dvrBufferMinutes = Int($0) }
                    ),
                    in: 5...30,
                    step: 5
                )
                .disabled(!dvrEnabled)

                HStack {
                    Text("5 min (\(dvrDiskSize(minutes: 5)))")
                    Spacer()
                    Text("30 min (\(dvrDiskSize(minutes: 30)))")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            SettingsSectionHeader(title: "FX", systemImage: "slider.horizontal.3")

            SettingsSectionBox {
                Toggle(isOn: $fxRememberPerShow) {
                    Text("Remember FX per show")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Saves and recalls your FX settings for each show individually. Synced across devices via iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                Toggle(isOn: $fxPersistAcrossShows) {
                    Text("FX settings persist across shows")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(fxRememberPerShow)

                Text("By default, all FX are reset when a new show starts. Enable this to keep your settings — though consider that the same settings will probably not work for different shows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.bottom, 16)
    }
}

// MARK: - Sync Settings

struct SyncSettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @State private var showRestartBanner: Bool = false

    private var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "iCloud", systemImage: "icloud")

            SettingsSectionBox {
                Toggle("Enable iCloud Sync", isOn: $iCloudSyncEnabled)
                    .disabled(!iCloudAvailable)
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        showRestartBanner = true
                    }

                if !iCloudAvailable {
                    Text("Sign in to iCloud in System Settings to enable sync.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Sync your listening history and favourites across all your devices.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if showRestartBanner {
                    Text("Restart ZappaStream to apply.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

        }
        .padding(.bottom, 16)
    }
}

// MARK: - Show Database Settings

struct ShowDatabaseSettingsView: View {
    @Query private var cachedShows: [CachedFZShow]
    @Query(sort: \FZShowsPageRecord.lastFetchedAt, order: .forward) private var pageRecords: [FZShowsPageRecord]

    private var oldestPageDate: Date? { pageRecords.first?.lastFetchedAt }

    private var lastUpdatedText: String {
        guard let date = oldestPageDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        SettingsSectionHeader(title: "FZShows Database", systemImage: "music.note.list")

        SettingsSectionBox {
            HStack {
                Text("\(cachedShows.count) shows across \(pageRecords.count) pages")
                    .font(.callout)
                Spacer()
                if FZShowsLog.shared.entries.isEmpty == false,
                   FZShowsLog.shared.entries.last?.contains("…") == true {
                    ProgressView().scaleEffect(0.7)
                }
            }

            HStack {
                Text("Last updated: \(lastUpdatedText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh Now") {
                    NotificationCenter.default.post(name: .refreshShowDatabase, object: nil)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }

            if cachedShows.isEmpty {
                Text("Show data is downloaded on first launch. This may take a moment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        // Activity log
        if !FZShowsLog.shared.entries.isEmpty {
            SettingsSectionBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(FZShowsLog.shared.entries.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry)
                            }
                        }
                        .onChange(of: FZShowsLog.shared.entries.count) { _, _ in
                            if let last = FZShowsLog.shared.entries.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    .frame(height: 80)
                }
            }
        }
    }
}

// MARK: - Saved Data Settings

struct SavedDataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.cacheModelContainer) private var cacheModelContainer
    @State private var showClearHistoryAlert = false
    @State private var showClearFavoritesAlert = false

    private var showDataManager: ShowDataManager {
        ShowDataManager(modelContext: modelContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "History", systemImage: "clock")

            SettingsSectionBox {
                Button(role: .destructive) {
                    showClearHistoryAlert = true
                } label: {
                    HStack {
                        Text("Clear History...")
                        Spacer()
                        Image(systemName: "trash")
                    }
                }
                .alert("Clear History", isPresented: $showClearHistoryAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        showDataManager.clearHistory()
                    }
                } message: {
                    Text("Are you sure you want to clear your entire listening history? This cannot be undone.")
                }

                Text("Remove all shows from your listening history.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsSectionHeader(title: "Favourites", systemImage: "star")

            SettingsSectionBox {
                Button(role: .destructive) {
                    showClearFavoritesAlert = true
                } label: {
                    HStack {
                        Text("Clear Favourites...")
                        Spacer()
                        Image(systemName: "trash")
                    }
                }
                .alert("Clear Favourites", isPresented: $showClearFavoritesAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        showDataManager.clearFavorites()
                    }
                } message: {
                    Text("Are you sure you want to remove all favourites? This cannot be undone.")
                }

                Text("Remove all shows from your favourites list.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let cacheContainer = cacheModelContainer {
                ShowDatabaseSettingsView()
                    .modelContainer(cacheContainer)
            } else {
                ShowDatabaseSettingsView()
            }

        }
        .padding(.bottom, 16)
    }
}

// MARK: - Credits

struct CreditsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Stream", systemImage: "antenna.radiowaves.left.and.right")

            SettingsSectionBox {
                Text("The streams are hosted by norbert.de.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    if let url = URL(string: "https://www.norbert.de/index.php/frank-zappa/") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Visit norbert.de")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }

            SettingsSectionHeader(title: "Show Information", systemImage: "list.bullet.rectangle")

            SettingsSectionBox {
                Text("Setlists, show information and original tape sources provided by the Zappateers community.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    if let url = URL(string: "https://www.zappateers.com") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Visit Zappateers")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }

            SettingsSectionHeader(title: "Audio Engine", systemImage: "waveform")

            SettingsSectionBox {
                Text("Audio playback and FX powered by BASS from un4seen.com.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    if let url = URL(string: "https://www.un4seen.com") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Visit un4seen.com")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }

            SettingsSectionHeader(title: "App", systemImage: "chevron.left.forwardslash.chevron.right")

            SettingsSectionBox {
                Text("ZappaStream is open source. Go here for general info and issue discussions.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    if let url = URL(string: "https://github.com/ZappaStream/ZappaStream") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("View on GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }

        }
        .padding(.bottom, 16)
    }
}

#Preview {
    SettingsView()
}
