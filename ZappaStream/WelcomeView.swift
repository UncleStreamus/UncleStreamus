//
//  WelcomeView.swift
//  ZappaStream
//
//  One-time "Welcome" sheet shown on a fresh install. Introduces the main
//  features and, most importantly, explains the quirks of the four stream
//  formats (MP3 / OGG / AAC / FLAC). Content is static. Platform-neutral so it
//  can be reused on macOS later; currently wired on iOS only.
//

import SwiftUI

struct WelcomeView: View {
    var onDismiss: () -> Void

    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let color: Color
        let blurb: String?
        let items: [Item]
    }

    // One line per format, capturing the real trade-off a newcomer should know.
    private var streamSection: Section {
        Section(
            title: "Choosing a stream",
            symbol: "antenna.radiowaves.left.and.right",
            color: .green,
            blurb: "Four formats are available. They're ordered below from worst to best sounding — pick the one that suits your connection:",
            items: [
                Item(title: "MP3 · 128 kbit/s",
                     detail: "Low data usage, but somtimes noticibly poor audio quality. Real-time track info."),
                Item(title: "OGG · 90 kbit/s",
                     detail: "Very low data usage, but decent sound quality. Real-time track info."),
                Item(title: "AAC · 256 kbit/s",
                     detail: "Average data usage and near perfect quality. But no built-in metadata, so now-playing info is fetched from MP3 stream and can run several minutes behind the audio."),
                Item(title: "FLAC · 750 kbit/s",
                     detail: "High data usage for lossless quality. Takes about 10 seconds to start while it builds its buffer, and needs a solid connection."),
            ]
        )
    }

    private var featuresSection: Section {
        Section(
            title: "More to explore",
            symbol: "sparkles",
            color: .blue,
            blurb: nil,
            items: [
                Item(title: "Continue buffering while paused",
                     detail: "Pause a stream and continue from where you left off for up to 30mins. Jump back to live when you're ready."),
                Item(title: "Audio FX",
                     detail: "A 3-band EQ, compressor and stereo controls to subtly improve the sound of each show. Settings can be remembered per show."),
                Item(title: "History & favourites",
                     detail: "Automatically saves a record of each show you listen (and on which device). Star shows you like to add them to favourites. Search and filter history and favourites by relevant keywords and data."),
                Item(title: "iCloud sync",
                     detail: "Your history, favourites and FX settings sync across your devices automatically."),
            ]
        )
    }

    private var sections: [Section] { [streamSection, featuresSection] }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button(action: onDismiss) {
                Text("I'm Ready!")
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
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .padding(.top, 24)
            Text("Welcome to UncleStreamus")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("24/7 Zappateers radio — hosted by Norbert.de")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.title, systemImage: section.symbol)
                .font(.headline)
                .foregroundStyle(section.color)

            if let blurb = section.blurb {
                Text(blurb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(section.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
