//
//  SettingsView.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 10/02/2026.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .sync

    enum SettingsTab {
        case sync, savedData

        var height: CGFloat {
            switch self {
            case .sync: return 200
            case .savedData: return 320
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Sync").tag(SettingsTab.sync)
                Text("Saved Data").tag(SettingsTab.savedData)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .sync:
                SyncSettingsView()
            case .savedData:
                SavedDataSettingsView()
            }
        }
        .frame(width: 400)
        .frame(height: selectedTab.height)
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
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 20)
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

                Text("Sync your listening history and favorites across all your devices.")
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

            SettingsSectionHeader(title: "Favorites", systemImage: "star")

            SettingsSectionBox {
                Button(role: .destructive) {
                    showClearFavoritesAlert = true
                } label: {
                    HStack {
                        Text("Clear Favorites...")
                        Spacer()
                        Image(systemName: "trash")
                    }
                }
                .alert("Clear Favorites", isPresented: $showClearFavoritesAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        showDataManager.clearFavorites()
                    }
                } message: {
                    Text("Are you sure you want to remove all favorites? This cannot be undone.")
                }

                Text("Remove all shows from your favorites list.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

#Preview {
    SettingsView()
}
