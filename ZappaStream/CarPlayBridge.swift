#if os(iOS)
import Foundation

/// Mirrors the playback/setlist state CarPlay's templates need to render.
///
/// `CarPlaySceneDelegate` runs in its own `UIScene` and has no access to
/// `ContentView_iOS`'s `@State private var bassPlayer` instance, so this singleton
/// is kept in sync by `ContentView_iOS` (see `syncCarPlayBridge()`) and read by
/// the CarPlay scene delegate whenever it receives `.carPlayDataChanged`.
@Observable
final class CarPlayBridge {
    static let shared = CarPlayBridge()
    private init() {}

    struct FormatOption {
        let format: String
        let label: String
    }

    var isPlaying = false
    var dvrState: BASSRadioPlayer.DVRState = .live
    var setlist: [String] = []
    var currentTrackIndex: Int?
    var selectedFormat = "MP3"
    var availableFormats: [FormatOption] = []
}

extension Notification.Name {
    /// Posted by `ContentView_iOS` whenever `CarPlayBridge.shared` changes.
    static let carPlayDataChanged = Notification.Name("carPlayDataChanged")

    /// Posted by `CarPlaySceneDelegate` when its interface controller connects;
    /// observed by `ContentView_iOS` to force a fresh Now Playing / bridge publish
    /// so CarPlay never starts from a stale pre-connection snapshot.
    static let carPlaySceneDidConnect = Notification.Name("carPlaySceneDidConnect")

    /// Posted by `CarPlaySceneDelegate` buttons; observed by `ContentView_iOS`
    /// to drive the actual `BASSRadioPlayer` (mirrors the macOS menubar pattern).
    static let carPlayStop = Notification.Name("carPlayStop")
    static let carPlayGoLive = Notification.Name("carPlayGoLive")
    /// userInfo: ["format": String] — e.g. "MP3", "OGG", "AAC", "FLAC"
    static let carPlaySelectFormat = Notification.Name("carPlaySelectFormat")
}
#endif
