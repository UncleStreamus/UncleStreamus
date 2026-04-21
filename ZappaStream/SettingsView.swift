//
//  SettingsView.swift
//  ZappaStream
//
//  Created by Datisit on 10/02/2026.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .playback

    enum SettingsTab {
        case playback, sync, savedData, credits

        var height: CGFloat {
            switch self {
            case .playback: return 500
            case .sync: return 200
            case .savedData: return 520
            case .credits: return 280
            }
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

            switch selectedTab {
            case .playback:
                PlaybackSettingsView()
            case .sync:
                SyncSettingsView()
            case .savedData:
                SavedDataSettingsView()
            case .credits:
                CreditsView()
            }

            #if os(iOS)
            Spacer()
            #endif
        }
        #if os(macOS)
        .frame(width: 400)
        .frame(height: selectedTab.height)
        #endif
        .navigationTitle("Settings")
        .transaction { transaction in
            transaction.animation = nil
        }
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
    @AppStorage("autoResumeOnLaunch") private var autoResumeOnLaunch: Bool = true
    @AppStorage("fxPersistAcrossShows") private var fxPersistAcrossShows: Bool = false
    @AppStorage("fxPersistOnRestart") private var fxPersistOnRestart: Bool = false
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

                Divider()
                    .padding(.vertical, 4)

                Toggle(isOn: $dvrEnabled) {
                    Text("Continue buffering while paused")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Keep the stream buffering when paused so you can resume from where you left off.")
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                Toggle(isOn: $fxPersistAcrossShows) {
                    Text("FX settings persist across shows")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("By default, all FX are reset when a new show starts. Enable this to keep your settings — though consider that the same settings will probably not work for different shows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)

                Toggle(isOn: $fxPersistOnRestart) {
                    Text("FX settings persist on app restart")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Restore your last FX settings when the app launches.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Sync Settings

struct SyncSettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "iCloud", systemImage: "icloud")

            SettingsSectionBox {
                Toggle("Enable iCloud Sync", isOn: $iCloudSyncEnabled)
                    .disabled(true)  // Disabled until CloudKit is configured

                Text("Sync your listening history and favourites across all your devices.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Coming soon")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()
        }
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

            ShowDatabaseSettingsView()

            Spacer()
        }
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

            Spacer()
        }
    }
}

#Preview {
    SettingsView()
}
