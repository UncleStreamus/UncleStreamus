#if os(iOS)
import Foundation

/// Mirrors the playback/setlist state CarPlay's templates need to render.
///
/// `CarPlaySceneDelegate` runs in its own `UIScene` and has no access to
/// `ContentView_iOS`'s `@State private var bassPlayer` instance, so this singleton
/// is the bridge: `ContentView_iOS` mirrors state in (see `syncCarPlayBridge()`)
/// and sets command hooks; the scene delegate reads the state, invokes the command
/// hooks from its buttons, and sets `onDataChanged` to be told when to re-render.
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

    // MARK: - Command hooks
    //
    // The CarPlay scene delegate runs in its own UIScene and can't reach
    // `ContentView_iOS`'s `@State`, so this singleton is the bridge. These typed
    // closures replace the old NotificationCenter channel (mirrors the macOS
    // menubar pattern in RadioViewModel).

    /// Scene → app commands, set by `ContentView_iOS.setupCarPlayHandlers()`.
    var onStop: () -> Void = {}
    var onGoLive: () -> Void = {}
    var onSelectFormat: (String) -> Void = { _ in }
    /// Scene → app: force a fresh now-playing/bridge publish after CarPlay connects
    /// so it never starts from a stale pre-connection snapshot.
    var onSceneConnect: () -> Void = {}

    /// App → scene: fired by `ContentView_iOS` after mirroring state so the scene
    /// delegate can rebuild its templates. Set by the scene delegate while
    /// connected, cleared on disconnect (nil = no CarPlay scene attached).
    var onDataChanged: (() -> Void)?
}
#endif
