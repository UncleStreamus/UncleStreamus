//
//  SettingsView.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 10/02/2026.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .playback

    enum SettingsTab {
        case playback, sync, savedData, credits

        var height: CGFloat {
            switch self {
            case .playback: return 200
            case .sync: return 200
            case .savedData: return 320
            case .credits: return 280
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Playback").tag(SettingsTab.playback)
                Text("Sync").tag(SettingsTab.sync)
                Text("Saved Data").tag(SettingsTab.savedData)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Launch", systemImage: "play.circle")

            SettingsSectionBox {
                Toggle("Resume playback on launch", isOn: $autoResumeOnLaunch)

                Text("Automatically continue playing when the app launches, if it was playing when you last quit.")
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

                Text("Coming soon - requires app to be published to the App Store.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()
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
                Text("Setlists and show information provided by the Zappateers community.")
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
