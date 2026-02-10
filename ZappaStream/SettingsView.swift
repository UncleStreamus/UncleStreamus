//
//  SettingsView.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 10/02/2026.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud Sync", isOn: $iCloudSyncEnabled)
                    .disabled(true)  // Disabled until CloudKit is configured

                Text("Sync your listening history and favorites across all your devices.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Coming soon - requires app to be published to the App Store.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } header: {
                Label("iCloud", systemImage: "icloud")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 180)
        .fixedSize()
    }
}

#Preview {
    SettingsView()
}
