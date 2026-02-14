import Foundation

class IcecastStreamReader: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var metadataInterval: Int = 0
    private var audioBuffer = Data()
    private var metadataLength: Int = 0
    private var bytesUntilMetadata: Int = 0
    private var isReadingMetadata = false
    private let bufferQueue = DispatchQueue(label: "com.zappastream.audiobuffer")

    var onMetadataUpdate: ((String) -> Void)?

    func startStreaming(url: URL) {
        stopStreaming()

        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        dataTask = session?.dataTask(with: request)
        dataTask?.resume()
    }

    func stopStreaming() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        bufferQueue.sync {
            audioBuffer.removeAll()
        }
        metadataInterval = 0
        bytesUntilMetadata = 0
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        if let httpResponse = response as? HTTPURLResponse {
            // Get the metadata interval from headers
            if let metaIntString = httpResponse.allHeaderFields["icy-metaint"] as? String,
               let metaInt = Int(metaIntString) {
                metadataInterval = metaInt
                bytesUntilMetadata = metaInt
                #if DEBUG
                print("✅ Icecast metadata interval: \(metaInt) bytes")
                #endif
            } else {
                #if DEBUG
                print("⚠️ No icy-metaint header found")
                #endif
            }

            #if DEBUG
            // Print all ICY headers for debugging
            for (key, value) in httpResponse.allHeaderFields {
                if let keyString = key as? String, keyString.lowercased().hasPrefix("icy") {
                    print("ICY Header: \(keyString) = \(value)")
                }
            }
            #endif
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bufferQueue.async {
            self.audioBuffer.append(data)
            self.processBuffer()
        }
    }

    private func processBuffer() {
        guard metadataInterval > 0 else {
            // No metadata, just discard audio data
            audioBuffer.removeAll()
            return
        }

        while audioBuffer.count > 0 {
            if !isReadingMetadata {
                // Reading audio data
                if audioBuffer.count >= bytesUntilMetadata {
                    // Discard audio chunk (playback handled by VLC)
                    audioBuffer.removeFirst(bytesUntilMetadata)

                    // Switch to reading metadata
                    isReadingMetadata = true
                    bytesUntilMetadata = 0
                } else {
                    // Not enough data yet
                    break
                }
            } else {
                // Reading metadata
                if metadataLength == 0 {

                    // Read metadata length byte
                    guard audioBuffer.count >= 1 else { break }

                    let lengthByte = audioBuffer.first!
                    metadataLength = Int(lengthByte) * 16
                    audioBuffer.removeFirst(1)

                    if metadataLength == 0 {
                        // No metadata this time
                        isReadingMetadata = false
                        bytesUntilMetadata = metadataInterval
                    }
                } else {
                    // Read metadata content
                    if audioBuffer.count >= metadataLength {
                        let metadataChunk = audioBuffer.prefix(metadataLength)
                        audioBuffer.removeFirst(metadataLength)

                        parseMetadata(metadataChunk)

                        // Reset for next cycle
                        metadataLength = 0
                        isReadingMetadata = false
                        bytesUntilMetadata = metadataInterval
                    } else {
                        // Not enough data yet
                        break
                    }
                }
            }
        }
    }

    private func parseMetadata(_ data: Data) {
        guard let metadataString = String(data: data, encoding: .utf8) else {
            return
        }

        #if DEBUG
        print("📻 Raw metadata: \(metadataString)")
        #endif

        // Parse StreamTitle='Artist - Title';
        if let range = metadataString.range(of: "StreamTitle='") {
            var title = String(metadataString[range.upperBound...])
            if let endRange = title.range(of: "';") {
                title = String(title[..<endRange.lowerBound])
                #if DEBUG
                print("🎵 Parsed title: \(title)")
                #endif
                DispatchQueue.main.async {
                    self.onMetadataUpdate?(title)
                }
            }
        }
    }
}
