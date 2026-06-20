//
//  ReleaseNotes.swift
//  ZappaStream
//
//  Model + loader for the bundled "What's New" release notes. The JSON is
//  generated at build time by Scripts/generate_release_notes.sh from git commit
//  subjects (see CLAUDE.md / .github/workflows/release.yml for the categories).
//

import Foundation

/// Release notes for a single build, decoded from the bundled `ReleaseNotes.json`.
struct ReleaseNotes: Codable, Identifiable {
    let build: String
    let version: String
    let new: [String]
    let improved: [String]
    let fixed: [String]
    /// True when these notes describe the build currently running. The generator
    /// falls back to the most recent release that *had* user-facing changes when the
    /// current build has none, so manual opening always shows something — but the
    /// launch auto-popup must only fire for genuinely new changes. Optional for
    /// backward-compatible decoding; absent → treat as current (prior behavior).
    let current: Bool?

    /// Stable identity for `.sheet(item:)`; the build number is unique per build.
    var id: String { build }

    var isEmpty: Bool { new.isEmpty && improved.isEmpty && fixed.isEmpty }

    /// Whether these notes belong to the running build (drives the launch auto-popup).
    var isCurrent: Bool { current ?? true }

    /// Loads the `ReleaseNotes.json` resource embedded by the build-phase script.
    /// Returns `nil` when the file is absent (e.g. a local build without the phase)
    /// or unreadable, in which case no "What's New" sheet is shown.
    static func loadBundled() -> ReleaseNotes? {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReleaseNotes.self, from: data)
    }

    /// The running app's build number (`CFBundleVersion`, e.g. "20260612").
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }
}
