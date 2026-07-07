//
//  WhatsNewView.swift
//  UncleStreamus
//
//  "What's New" sheet shown on first launch after a build update. Renders the
//  bundled `ReleaseNotes` (New / Improved / Fixed) generated from commit messages.
//  Platform-neutral so it can be reused on macOS later.
//

import SwiftUI

struct WhatsNewView: View {
    let notes: ReleaseNotes
    var onDismiss: () -> Void

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let color: Color
        let items: [String]
    }

    private var sections: [Section] {
        [
            Section(title: "New", symbol: "sparkles", color: .green, items: notes.new),
            Section(title: "Improved", symbol: "wand.and.stars", color: .blue, items: notes.improved),
            Section(title: "Fixed", symbol: "wrench.and.screwdriver.fill", color: .orange, items: notes.fixed),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                if sections.isEmpty {
                    Text("No notable changes in this version.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button(action: onDismiss) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(16)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .padding(.top, 24)
            Text("What's New")
                .font(.largeTitle.bold())
            Text(versionLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private var versionLine: String {
        var parts: [String] = []
        if !notes.version.isEmpty { parts.append("Version \(notes.version)") }
        if !notes.build.isEmpty { parts.append("(\(notes.build))") }
        return parts.joined(separator: " ")
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.title, systemImage: section.symbol)
                .font(.headline)
                .foregroundStyle(section.color)

            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .foregroundStyle(section.color)
                    Text(verbatim: item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
            }
        }
    }
}
