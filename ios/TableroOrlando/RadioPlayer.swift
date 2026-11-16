import AVFoundation
import MediaPlayer

/// Reproduce la radio con iOS, así sigue sonando con la pantalla bloqueada o con Waze encima.
/// Los controles de la pantalla bloqueada (y del Centro de control) funcionan aquí mismo,
/// aunque la página esté pausada en segundo plano.
final class RadioPlayer: NSObject {

    struct Station {
        let id: String
        let name: String
        let url: URL
    }

    var onEvent: ((String) -> Void)?        // "playing", "waiting", "error"
    var onStation: ((String) -> Void)?      // id de la emisora que cambió desde la pantalla bloqueada
    var onStopped: (() -> Void)?            // pausada desde la pantalla bloqueada

    private var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var stations: [Station] = []
    private var index = 0
    private var currentURL: URL?
    private var currentTitle = "Radio"
    private var wantsToPlay = false

    override init() {
        super.init()
        setUpRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleStreamEnded(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
    }

    func play(url: URL, title: String, list: [Station], index: Int) {
        if !list.isEmpty {
            stations = list
            self.index = min(max(0, index), list.count - 1)
        }
        start(url: url, title: title)
    }

    func stop() {
        wantsToPlay = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Devuelve el audio a otras apps (por ejemplo Spotify).
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(url: URL, title: String) {
        currentURL = url
        currentTitle = title
        wantsToPlay = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        if player == nil {
            player = AVPlayer()
            player?.automaticallyWaitsToMinimizeStalling = true
        }
        player?.replaceCurrentItem(with: item)

        statusObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, self.wantsToPlay else { return }
                switch p.timeControlStatus {
                case .playing: self.onEvent?("playing")
                case .waitingToPlayAtSpecifiedRate: self.onEvent?("waiting")
                default: break
                }
            }
        }
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            DispatchQueue.main.async { self?.onEvent?("error") }
        }

        player?.play()
        updateNowPlaying()
    }

    private func step(_ delta: Int) {
        guard !stations.isEmpty else { return }
        index = (index + delta + stations.count) % stations.count
        let st = stations[index]
        start(url: st.url, title: st.name)
        onStation?(st.id)
    }

    private func resume() {
        if let url = currentURL {
            start(url: url, title: currentTitle)
            if index < stations.count { onStation?(stations[index].id) }
        } else if let first = stations.first {
            index = 0
            start(url: first.url, title: first.name)
            onStation?(first.id)
        }
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Radio en vivo",
            MPMediaItemPropertyAlbumTitle: "Tablero Orlando",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.stop(); self?.onStopped?(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.wantsToPlay { self.stop(); self.onStopped?() } else { self.resume() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.step(1); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.step(-1); return .success
        }
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// Llamada telefónica, Siri, etc.: al terminar, la radio vuelve a sonar.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended && wantsToPlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.wantsToPlay, let url = self.currentURL else { return }
                self.start(url: url, title: self.currentTitle)
            }
        }
    }

    /// Si la transmisión se corta (mala señal), reintenta.
    @objc private func handleStreamEnded(_ note: Notification) {
        guard wantsToPlay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wantsToPlay, let url = self.currentURL else { return }
            self.start(url: url, title: self.currentTitle)
        }
    }
}
