#if os(iOS)
import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?

    private var setlistTemplate: CPListTemplate?
    private var formatTemplate: CPListTemplate?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons()

        interfaceController.setRootTemplate(nowPlaying, animated: false, completion: nil)

        // App → scene refresh hook: ContentView_iOS fires this after it mirrors
        // state into the bridge, so we rebuild our templates (replaces the old
        // .carPlayDataChanged observer).
        CarPlayBridge.shared.onDataChanged = { [weak self] in
            self?.handleBridgeUpdate()
        }

        // Force a fresh publish of MPNowPlayingInfoCenter / CarPlayBridge — CarPlay
        // can connect well after the app already published its initial state (e.g.
        // auto-resume on launch), so without this the Now Playing screen can start
        // from a stale snapshot (wrong play/pause icon) until some other action
        // happens to republish.
        CarPlayBridge.shared.onSceneConnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayBridge.shared.onDataChanged = nil
        setlistTemplate = nil
        formatTemplate = nil
        self.interfaceController = nil
    }

    private func handleBridgeUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.updateNowPlayingButtons()
            self?.refreshSetlistTemplate()
            self?.refreshFormatTemplate()
        }
    }

    // MARK: - Now Playing transport buttons

    /// CPNowPlayingTemplate allows at most 5 custom buttons. Stop and the
    /// Setlist/Format shortcuts are always shown; the DVR action button and
    /// "Go Live" adapt to `dvrState` (mirrors the phone UI's button logic).
    private func updateNowPlayingButtons() {
        let bridge = CarPlayBridge.shared
        var buttons: [CPNowPlayingButton] = [
            nowPlayingImageButton(systemName: "stop.fill") {
                CarPlayBridge.shared.onStop()
            }
        ]

        // The system's built-in transport button (top of the Now Playing screen)
        // already drives play/pause/resume via MPRemoteCommandCenter — a custom
        // button here would duplicate it, and the two could show conflicting
        // states. "Go Live" has no system equivalent, so it's the only DVR action
        // that still needs a custom button.
        if bridge.dvrState != .live {
            buttons.append(nowPlayingImageButton(systemName: "dot.radiowaves.left.and.right") {
                CarPlayBridge.shared.onGoLive()
            })
        }

        buttons.append(nowPlayingImageButton(systemName: "list.bullet") { [weak self] in
            self?.showSetlist()
        })
        buttons.append(nowPlayingImageButton(systemName: "slider.horizontal.3") { [weak self] in
            self?.showFormatPicker()
        })

        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    private func nowPlayingImageButton(systemName: String, handler: @escaping () -> Void) -> CPNowPlayingImageButton {
        CPNowPlayingImageButton(image: UIImage(systemName: systemName) ?? UIImage()) { _ in
            handler()
        }
    }

    // MARK: - Setlist

    private func showSetlist() {
        guard let interfaceController else { return }
        let template = setlistTemplate ?? makeSetlistTemplate()
        setlistTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func makeSetlistTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Setlist", sections: setlistSections())
        template.emptyViewTitleVariants = ["No Setlist Available"]
        template.emptyViewSubtitleVariants = ["Setlist appears once the show is identified"]
        return template
    }

    private func refreshSetlistTemplate() {
        setlistTemplate?.updateSections(setlistSections())
    }

    private func setlistSections() -> [CPListSection] {
        let bridge = CarPlayBridge.shared
        let nowPlayingImage = UIImage(systemName: "speaker.wave.2.fill")
        let items = bridge.setlist.enumerated().map { index, trackName -> CPListItem in
            // currentTrackIndex mirrors ContentView_iOS's currentSetlistPosition, which is
            // 1-based (see findCurrentTrackPosition's `index + 1`); enumerated() is 0-based.
            let isCurrent = index + 1 == bridge.currentTrackIndex
            let item = CPListItem(
                text: trackName,
                detailText: nil,
                image: nil,
                accessoryImage: isCurrent ? nowPlayingImage : nil,
                accessoryType: .none
            )
            item.handler = { _, completion in completion() }
            return item
        }
        return [CPListSection(items: items)]
    }

    // MARK: - Format picker

    private func showFormatPicker() {
        guard let interfaceController else { return }
        let template = formatTemplate ?? makeFormatTemplate()
        formatTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func makeFormatTemplate() -> CPListTemplate {
        CPListTemplate(title: "Stream Quality", sections: formatSections())
    }

    private func refreshFormatTemplate() {
        formatTemplate?.updateSections(formatSections())
    }

    private func formatSections() -> [CPListSection] {
        let bridge = CarPlayBridge.shared
        let checkmark = UIImage(systemName: "checkmark")
        let items = bridge.availableFormats.map { option -> CPListItem in
            let isSelected = option.format == bridge.selectedFormat
            let item = CPListItem(
                text: option.label,
                detailText: nil,
                image: nil,
                accessoryImage: isSelected ? checkmark : nil,
                accessoryType: .none
            )
            item.handler = { [weak self] _, completion in
                CarPlayBridge.shared.onSelectFormat(option.format)
                completion()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        return [CPListSection(items: items)]
    }
}
#endif
