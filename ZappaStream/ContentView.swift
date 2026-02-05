import SwiftUI
import AVFoundation
import VLCKit

struct ContentView: View {
    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var currentTrack: String = "No track info"
    @State private var parsedTrack: ParsedTrackInfo?
    @State private var mediaPlayer: VLCMediaPlayer?
    @State private var streamReader: IcecastStreamReader?
    @State private var currentShow: FZShow?
    @State private var showInfoExpanded: Bool = false
    @State private var isFetchingShowInfo: Bool = false
    @State private var expandedAcronyms: Set<String> = []
    @State private var availableWidth: CGFloat = 500
    
    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "AAC (192 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "OGG (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Zappa Stream")
                .font(.largeTitle)
                .bold()
            
            VStack(alignment: .leading, spacing: 8) {
                if let parsed = parsedTrack, currentTrack != "No track info" && !currentTrack.isEmpty {
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if let trackName = parsed.trackName {
                            Text(trackName)
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            if let artist = parsed.artist {
                                Text(artist).font(.subheadline).foregroundColor(.secondary)
                            }
                            if let trackNumber = parsed.trackNumber {
                                Text("• Track \(trackNumber)").font(.caption).foregroundColor(.secondary)
                            }
                            if let trackDuration = parsed.trackDuration {
                                Text("• \(trackDuration)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        if let date = parsed.date, let city = parsed.city, let state = parsed.state {
                            Text("\(date) • \(city), \(state)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let source = parsed.source {
                            Text(source)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                        }
                        
                    }
                } else {
                    Text("No track info")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
            }
            .frame(minHeight: 100)
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            // Show Info Section
            if let show = currentShow {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: {
                        showInfoExpanded.toggle()
                    }) {
                        HStack {
                            Text("Show Info")
                                .font(.headline)
                            Spacer()
                            Image(systemName: showInfoExpanded ? "chevron.up" : "chevron.down")
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    if showInfoExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            // Venue, note, and show info grouped tightly
                            VStack(alignment: .leading, spacing: 2) {
                                Text(show.venue)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let note = show.note {
                                    Text(try! AttributedString(markdown: note))
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                
                                if !show.showInfo.isEmpty {
                                    Text(show.showInfo)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Divider()
                            
                            // Setlist
                            Text("Setlist:")
                                .font(.headline)

                            ScrollView {
                                Group {
                                    if availableWidth > 350 {  // Two columns if wide enough
                                        HStack(alignment: .top, spacing: 20) {
                                            let midpoint = (show.setlist.count + 1) / 2
                                            
                                            // First column
                                            VStack(alignment: .leading, spacing: 4) {
                                                ForEach(Array(show.setlist.prefix(midpoint).enumerated()), id: \.offset) { index, song in
                                                    HStack(alignment: .top, spacing: 4) {
                                                        Text("\(index + 1). ")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                        
                                                        formatSongWithAcronyms(song: song,
                                                                              acronyms: show.acronyms,
                                                                              expandedAcronyms: $expandedAcronyms)  // ← Add this
                                                            .font(.caption)
                                                    }
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            
                                            // Second column
                                            if show.setlist.count > midpoint {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    ForEach(Array(show.setlist.dropFirst(midpoint).enumerated()), id: \.offset) { index, song in
                                                        HStack(alignment: .top, spacing: 4) {
                                                            Text("\(midpoint + index + 1). ")
                                                                .font(.caption)
                                                                .foregroundColor(.secondary)
                                                            
                                                            formatSongWithAcronyms(song: song,
                                                                                    acronyms: show.acronyms,
                                                                                    expandedAcronyms: $expandedAcronyms)  // ← Add this
                                                                  .font(.caption)
                                                        }
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    } else {  // Single column if narrow
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(show.setlist.enumerated()), id: \.offset) { index, song in
                                                HStack(alignment: .top, spacing: 4) {
                                                    Text("\(index + 1). ")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    
                                                    formatSongWithAcronyms(song: song,
                                                                          acronyms: show.acronyms,
                                                                          expandedAcronyms: $expandedAcronyms)  // ← Add this
                                                        .font(.caption)
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 4)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.onAppear {
                                            availableWidth = geo.size.width
                                        }
                                        .onChange(of: geo.size.width) { _, newWidth in
                                            availableWidth = newWidth
                                        }
                                    }
                                )
                            }
                            .frame(maxHeight: 200)
                            
                            // Link to website
                            Button("View on FZShows website") {
                                if let url = URL(string: show.url) {
                                    #if os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #else
                                    // For iOS, we'll add Safari View Controller later
                                    #endif
                                }
                            }
                            .font(.caption)
                            .padding(.top, 8)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
            } else if isFetchingShowInfo {
                HStack {
                    ProgressView()
                    Text("Loading show info...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            
            Picker("Select Stream:", selection: $selectedStream) {
                Text("Choose stream...").tag(nil as Stream?)
                ForEach(streams) { stream in
                    Text(stream.name).tag(stream as Stream?)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedStream) { _, newValue in
                if newValue != nil && isPlaying {
                    playStream()
                }
            }
            
            Button(action: {
                if isPlaying { stopStream() } else { playStream() }
            }) {
                Text(isPlaying ? "Pause" : "Play")
                    .font(.title)
                    .padding()
                    .frame(width: 150)
                    .background(isPlaying ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(selectedStream == nil)
            
            if let stream = selectedStream {
                Text("Playing: \(stream.format)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .frame(
            minWidth: 350,
            idealWidth: showInfoExpanded ? 450 : 350,
            minHeight: showInfoExpanded ? 695 : 500
        )
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: stopStream)
    }
    
    func setupPlayer() {
        mediaPlayer = VLCMediaPlayer()
        streamReader = IcecastStreamReader()
        
        streamReader?.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                self.currentTrack = metadata
                self.parsedTrack = ParsedTrackInfo.parse(metadata)
                
                if let parsed = self.parsedTrack, let date = parsed.date {
                    print("📊 Parsed meta")
                    print("   Date: \(date)")
                    print("   City: \(parsed.city ?? "?"), State: \(parsed.state ?? "?")")
                    print("   Artist: \(parsed.artist ?? "?")")
                    print("   Track: #\(parsed.trackNumber ?? "?") - \(parsed.trackName ?? "?")")
                    print("   Source: \(parsed.source ?? "?") Gen: \(parsed.generation ?? "?")")
                    print("   Duration: \(parsed.trackDuration ?? "?")")
                    
                    self.fetchShowInfo(date: date)
                }
            }
        }
        
        // Timers should be here, NOT inside the callback
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            self.pollMP3Metadata()
        }
        
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            self.checkAACState()
        }
    }
    
    private func checkAACState() {
        guard let player = mediaPlayer,
              isPlaying,
              selectedStream?.format == "AAC",
              player.state.rawValue == 6 else { return }
        
        print("🔄 AAC restart triggered")
        playStream()
    }
    
    func playStream() {
        mediaPlayer?.stop()
        streamReader?.stopStreaming()
        
        guard let stream = selectedStream, let url = URL(string: stream.url) else { return }
        
        if stream.format == "MP3" {
            streamReader?.startStreaming(url: url)
        } else {
            streamReader?.stopStreaming()
        }
        
        let media = VLCMedia(url: url)
        if stream.format == "AAC" {
            media.addOptions(["network-caching": "3000"])
        }
        mediaPlayer?.media = media
        mediaPlayer?.play()
        isPlaying = true
    }
    
    func stopStream() {
        mediaPlayer?.pause()
        streamReader?.stopStreaming()
        isPlaying = false
    }
    
    
    @ViewBuilder
    func formatSongWithAcronyms(
        song: String,
        acronyms: [(short: String, full: String)],
        expandedAcronyms: Binding<Set<String>>
    ) -> some View {
        let bracketPattern = #"\[[^\]]+\]"#
        
        if let bracketRange = song.range(of: bracketPattern, options: .regularExpression) {
            let beforeBracket = String(song[..<bracketRange.lowerBound])
            let bracketContent = String(song[bracketRange])
            
            let matchingAcronyms = acronyms.filter { acronym in
                bracketContent.contains(acronym.short)
            }
            
            if !matchingAcronyms.isEmpty {
                buildConcatenatedText(beforeBracket: beforeBracket, bracketContent: bracketContent, acronyms: matchingAcronyms, expandedAcronyms: expandedAcronyms)
            } else {
                Text(beforeBracket + bracketContent)
            }
        } else {
            Text(song)
        }
    }

    func buildConcatenatedText(
        beforeBracket: String,
        bracketContent: String,
        acronyms: [(short: String, full: String)],
        expandedAcronyms: Binding<Set<String>>
    ) -> some View {
        var result = Text(beforeBracket)
        var remainingText = bracketContent
        
        let sortedAcronyms = acronyms.sorted { first, second in
            let range1 = remainingText.range(of: first.short)
            let range2 = remainingText.range(of: second.short)
            if let r1 = range1, let r2 = range2 {
                return r1.lowerBound < r2.lowerBound
            }
            return range1 != nil
        }
        
        for acronym in sortedAcronyms {
            if let range = remainingText.range(of: acronym.short) {
                let before = String(remainingText[..<range.lowerBound])
                if !before.isEmpty {
                    result = result + Text(before).foregroundColor(.white).italic()
                }
                
                let isExpanded = expandedAcronyms.wrappedValue.contains(acronym.short)
                let displayText = isExpanded ? acronym.full : acronym.short
                
                // Unfortunately we can't add tap gesture to concatenated text
                // So we'll just show the acronym in blue/bold/underline
                result = result + Text(displayText)
                    .foregroundColor(.blue)
                    .bold()
                    .underline()
                
                remainingText = String(remainingText[range.upperBound...])
            }
        }
        
        if !remainingText.isEmpty {
            result = result + Text(remainingText).foregroundColor(.white).italic()
        }
        
        return result
    }

    
    func pollMP3Metadata() {
        guard let selectedStream = selectedStream,
              (selectedStream.format == "OGG" || selectedStream.format == "FLAC" || selectedStream.format == "AAC"),
              isPlaying else { return }
        
        let tempReader = IcecastStreamReader()
        tempReader.onMetadataUpdate = { metadata in
            if !metadata.isEmpty {
                DispatchQueue.main.async {
                    self.currentTrack = metadata
                    self.parsedTrack = ParsedTrackInfo.parse(metadata)
                    
                    if let parsed = self.parsedTrack {
                        print("📊 Parsed metadata (from MP3 poll):")
                        print("   Track: #\(parsed.trackNumber ?? "?") - \(parsed.trackName ?? "?")")
                        
                        
                        if let date = parsed.date {
                            self.fetchShowInfo(date: date)
                       }
                    }
                }
            }
            tempReader.stopStreaming()
        }
        
        if let mp3URL = URL(string: "https://shoutcast.norbert.de/zappa.mp3") {
            tempReader.startStreaming(url: mp3URL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                tempReader.stopStreaming()
            }
        }
    }
    
    func fetchShowInfo(date: String) {
        // Only fetch if we don't already have this show
        guard currentShow?.date != date else { return }
        
        isFetchingShowInfo = true
        FZShowsFetcher.fetchShowInfo(date: date) { show in
            DispatchQueue.main.async {
                self.currentShow = show
                self.isFetchingShowInfo = false
                
                if let show = show {
                    print("✅ Fetched show info for \(show.date)")
                    print("   Venue: \(show.venue)")
                    print("   Setlist: \(show.setlist.count) songs")
                }
            }
        }
    }
}
