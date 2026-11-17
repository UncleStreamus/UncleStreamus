//
//  Stream.swift
//  UncleStreamus
//
//  Created by Darcy Taranto on 04/02/2026.
//

import Foundation

struct Stream: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: String
    let format: String
}

extension Stream {
    /// The four Zappateers stream formats — the single source for every picker, menu,
    /// CarPlay list and engine URL lookup. A `static let` so each `Stream` keeps one
    /// stable `id` for the life of the process (the `UUID()` is minted once, here).
    static let all: [Stream] = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "OGG (90 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "AAC (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC"),
    ]

    /// Format used when the user has never picked one (`lastStreamFormat` unset).
    static let defaultFormat = "OGG"

    /// The stream for a format string ("MP3", "OGG", "AAC", "FLAC"), if it exists.
    static func forFormat(_ format: String) -> Stream? {
        all.first { $0.format == format }
    }
}
