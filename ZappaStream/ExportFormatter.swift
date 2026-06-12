import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// MARK: - Show text formatter

enum ShowExporter {

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    private static let wrapWidth = 50

    static func exportText(
        shows: [SavedShow],
        sectionName: String,
        includeListenDate: Bool,
        filterDescription: String?
    ) -> String {
        let divider = String(repeating: "─", count: 40)
        var lines: [String] = []

        let today = exportDateString(Date())
        let countWord = shows.count == 1 ? "1 show" : "\(shows.count) shows"

        lines.append("ZappaStream — \(sectionName)")
        lines.append("\(countWord)  ·  Exported \(today)")
        if let filter = filterDescription {
            lines.append("Filtered by: \(filter)")
        }

        guard !shows.isEmpty else {
            lines.append("")
            lines.append("No shows to export.")
            return lines.joined(separator: "\n")
        }

        let width = shows.count >= 100 ? 3 : 2
        let indent = "      "
        let cont   = indent + "  "

        for (index, show) in shows.enumerated() {
            lines.append(divider)
            lines.append("")

            let numStr = String(format: "%\(width)d.", index + 1)
            lines.append(" \(numStr)  \(formatShowDate(show.showDate))")

            // Venue
            if !show.venue.isEmpty {
                lines += wrap(show.venue, prefix: indent, cont: cont)
            }

            // Location — suppress if already embedded in the venue string
            var geo: [String] = []
            if let c = show.city, !c.isEmpty { geo.append(c) }
            if let s = show.state, !s.isEmpty { geo.append(s) }
            if let c = show.country, !c.isEmpty { geo.append(c) }
            let geoStr = geo.joined(separator: ", ")
            if !geoStr.isEmpty && !show.venue.contains(geoStr) {
                lines += wrap(geoStr, prefix: indent, cont: cont)
            }

            // Period and Tour on separate lines
            if let p = show.period, !p.isEmpty { lines += wrap(p, prefix: indent, cont: cont) }
            if let t = show.tour,   !t.isEmpty { lines += wrap(t, prefix: indent, cont: cont) }

            // Show info
            if !show.showInfo.isEmpty {
                lines += wrap("Info: \(show.showInfo)", prefix: indent, cont: indent + "      ")
            }

            // Listened date (History tab only)
            if includeListenDate, let listenedAt = show.listenedAt {
                lines.append("\(indent)Listened: \(exportDateString(listenedAt))")
            }

            // Note
            if let note = show.note, !note.isEmpty {
                lines += wrap("⚠ \(note)", prefix: indent, cont: cont)
            }

            // Setlist
            let setlist = show.setlist
            if !setlist.isEmpty {
                lines.append("")
                lines.append("\(indent)Setlist:")
                for (i, track) in setlist.enumerated() {
                    let numPart = "\(i + 1). "
                    let trackPrefix = indent + "  " + numPart
                    let trackCont   = indent + "  " + String(repeating: " ", count: numPart.count)
                    lines += wrap(track, prefix: trackPrefix, cont: trackCont)
                }
            }

            // Releases (acronym expansions)
            let acronyms = show.acronyms
            if !acronyms.isEmpty {
                let releaseStr = acronyms.map { "\($0.short) = \($0.full)" }.joined(separator: ", ")
                lines.append("")
                lines += wrap("Releases: \(releaseStr)", prefix: indent, cont: indent + "          ")
            }

            // Zappateers URL
            if !show.url.isEmpty {
                lines.append("")
                lines.append(indent + show.url)
            }

            lines.append("")
        }

        lines.append(divider)
        return lines.joined(separator: "\n")
    }

    private static func wrap(_ text: String, prefix: String, cont: String) -> [String] {
        guard (prefix + text).count > wrapWidth else { return [prefix + text] }
        var result: [String] = []
        var remaining = text
        var isFirst = true
        while !remaining.isEmpty {
            let pfx = isFirst ? prefix : cont
            isFirst = false
            let budget = wrapWidth - pfx.count
            guard budget > 0 else { result.append(pfx + remaining); break }
            if remaining.count <= budget { result.append(pfx + remaining); break }
            let endIdx = remaining.index(remaining.startIndex, offsetBy: budget)
            if let spaceIdx = remaining[..<endIdx].lastIndex(of: " ") {
                result.append(pfx + String(remaining[..<spaceIdx]))
                remaining = String(remaining[remaining.index(after: spaceIdx)...])
            } else {
                result.append(pfx + String(remaining[..<endIdx]))
                remaining = String(remaining[endIdx...])
            }
        }
        return result
    }

    static func suggestedFilename(section: String) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        let date = String(iso.prefix(10))
        let time = String(iso.dropFirst(11).prefix(5)).replacingOccurrences(of: ":", with: "-")
        return "ZappaStream \(section) \(date) \(time).txt"
    }

    static func formatShowDate(_ showDate: String) -> String {
        let parts = showDate.split(separator: " ")
        guard parts.count >= 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              month >= 1, month <= 12 else { return showDate }
        var result = "\(day) \(monthNames[month - 1]) \(year)"
        if parts.count >= 4 {
            switch String(parts[3]) {
            case "E": result += " (Early show)"
            case "L": result += " (Late show)"
            default: break
            }
        }
        return result
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func exportDateString(_ date: Date) -> String {
        exportDateFormatter.string(from: date)
    }
}

// MARK: - FileDocument (macOS Save As dialog)

struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var content: String

    init(content: String) { self.content = content }

    init(configuration: ReadConfiguration) throws {
        content = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

// MARK: - Export button (platform-adaptive, lazy evaluation)
//
// makeExport is called only when the user taps — never during view rendering.
// This avoids accessing SwiftData model objects at render time.

struct ExportButton: View {
    let makeExport: () -> (content: String, filename: String)

    #if os(macOS)
    @State private var isExporting = false
    @State private var exportContent = ""
    @State private var exportFilename = "export.txt"
    #else
    @State private var shareItem: ExportShareItem? = nil
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            let pair = makeExport()
            exportContent = pair.content
            exportFilename = pair.filename
            isExporting = true
        } label: {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Export list as text file")
        .fileExporter(
            isPresented: $isExporting,
            document: PlainTextDocument(content: exportContent),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in }

        #else
        Button {
            let pair = makeExport()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(pair.filename)
            try? pair.content.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ExportShareItem(url: url)
        } label: {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
        .help("Export list as text file")
        .sheet(item: $shareItem) { item in
            ExportActivityView(url: item.url)
                .presentationDetents([.medium, .large])
        }
        #endif
    }
}

// MARK: - Full-width export row (for Settings > Data pane)

struct ExportRow: View {
    let title: String
    let makeExport: () -> (content: String, filename: String)

    #if os(macOS)
    @State private var isExporting = false
    @State private var exportContent = ""
    @State private var exportFilename = "export.txt"
    #else
    @State private var shareItem: ExportShareItem? = nil
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            let pair = makeExport()
            exportContent = pair.content
            exportFilename = pair.filename
            isExporting = true
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.down.circle")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: PlainTextDocument(content: exportContent),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in }

        #else
        Button {
            let pair = makeExport()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(pair.filename)
            try? pair.content.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ExportShareItem(url: url)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.down.circle")
            }
        }
        .sheet(item: $shareItem) { item in
            ExportActivityView(url: item.url)
                .presentationDetents([.medium, .large])
        }
        #endif
    }
}

#if os(iOS)
private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ExportActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
