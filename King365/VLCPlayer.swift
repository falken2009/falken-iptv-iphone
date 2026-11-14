import SwiftUI
import UIKit
import VLCKitSPM

// MARK: - Pilotage du lecteur VLC (MKV, AVI, TS…)

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

@MainActor
final class VLCController: ObservableObject {
    let player = VLCMediaPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var buffering = true
    @Published private(set) var failed = false
    @Published private(set) var ended = false
    @Published private(set) var position: Double = 0
    @Published private(set) var timeText = "0:00"
    @Published private(set) var lengthText = ""
    @Published private(set) var hasLength = false
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitles: [MediaTrack] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1

    private var poll: Task<Void, Never>?
    private let resumeKey: String?
    private let item: PlayItem?
    private var pendingStart: Double?
    private var ticks = 0
    private var wantsMuted = false
    /// Pause demandée par l'utilisateur (sinon on relance tout seul)
    private var userPaused = false
    private var reconnects = 0
    private var everPlayed = false
    private var startedAt = Date()
    private var startRetried = false
    private var lastReconnect = Date.distantPast

    init(url: URL, resumeKey: String? = nil, startAt: Double? = nil, muted: Bool = false, item: PlayItem? = nil) {
        self.resumeKey = resumeKey
        self.item = item
        self.pendingStart = startAt
        let media = VLCMedia(url: url)
        // Réserve plus petite pour le direct : la chaîne démarre plus vite
        let isLive = resumeKey == nil && !(item?.autoNext ?? false)
        media.addOption(isLive ? ":network-caching=1200" : ":network-caching=2000")
        media.addOption(":live-caching=1200")
        media.addOption(":http-user-agent=\(Net.userAgent)")
        media.addOption(":http-reconnect")
        player.media = media
        wantsMuted = muted
    }

    func setMuted(_ muted: Bool) {
        wantsMuted = muted
        player.audio?.volume = muted ? 0 : 100
    }

    func saveProgress() {
        guard let key = resumeKey else { return }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        let time = Double(player.time.intValue) / 1000
        if let item {
            WatchProgress.save(item: item, position: time, duration: length)
        } else {
            WatchProgress.save(key: key, position: time, duration: length)
        }
    }

    func attach(_ view: UIView) {
        player.drawable = view
    }

    func start() {
        startedAt = Date()
        player.play()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func shutdown() {
        saveProgress()
        poll?.cancel()
        poll = nil
        player.stop()
    }

    func togglePlay() {
        if player.isPlaying {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            player.play()
        }
        refresh()
    }

    func seek(to value: Double) {
        player.position = Float(min(max(value, 0), 1))
    }

    func jump(seconds: Int32) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    private func refresh() {
        isPlaying = player.isPlaying

        // Reprise : on se place au bon endroit dès que la lecture a démarré
        if let start = pendingStart, player.isPlaying {
            player.time = VLCTime(int: Int32(start * 1000))
            pendingStart = nil
        }
        ticks += 1
        if ticks % 10 == 0 { saveProgress() }
        // Le son n'est réglable qu'une fois la lecture lancée : on réapplique le choix
        if wantsMuted, let audio = player.audio, audio.volume != 0 { audio.volume = 0 }

        let isLive = (player.media?.length.intValue ?? 0) <= 0
        if player.isPlaying { reconnects = 0; everPlayed = true }
        let dropped = player.state == .error || player.state == .ended || (player.state == .stopped && everPlayed)

        if isLive && dropped && !userPaused && reconnects < (everPlayed ? 5 : 1) {
            // Direct coupé : on se reconnecte tout seul (5 essais)
            if Date().timeIntervalSince(lastReconnect) > 3 {
                reconnects += 1
                lastReconnect = Date()
                player.stop()
                player.play()
            }
            buffering = true
            return
        }

        // Démarrage qui n'aboutit pas : un nouvel essai à 12 s, puis un message clair à 25 s
        // (au lieu d'un rond qui tourne sans fin)
        if !everPlayed && !userPaused {
            let waited = Date().timeIntervalSince(startedAt)
            // Direct : on abandonne plus vite pour essayer l'autre format de la chaîne
            let (retryAt, giveUpAt): (TimeInterval, TimeInterval) = isLive ? (7, 14) : (12, 25)
            if waited > giveUpAt {
                failed = true
                buffering = false
                return
            }
            if waited > retryAt && !startRetried {
                startRetried = true
                player.stop()
                player.play()
            }
        }

        switch player.state {
        case .paused where isLive && !userPaused:
            player.play()
        case .error:
            failed = true
            buffering = false
        case .ended:
            ended = true
            buffering = false
        case .opening, .buffering:
            buffering = !player.isPlaying
        default:
            buffering = false
        }

        let length = player.media?.length.intValue ?? 0
        hasLength = length > 0
        if hasLength {
            position = Double(player.position)
            lengthText = Self.format(length)
        }
        timeText = Self.format(player.time.intValue)

        audioTracks = Self.tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes)
        subtitles = Self.tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
        currentAudio = player.currentAudioTrackIndex
        currentSubtitle = player.currentVideoSubTitleIndex
    }

    private static func tracks(names: [Any]?, ids: [Any]?) -> [MediaTrack] {
        let n = (names as? [String]) ?? []
        let i = ((ids as? [NSNumber]) ?? []).map(\.int32Value)
        return zip(i, n).map { MediaTrack(id: $0, name: $1) }
    }

    private static func format(_ milliseconds: Int32) -> String {
        let total = max(Int(milliseconds) / 1000, 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Surface vidéo sur laquelle VLC dessine l'image
struct VLCVideoSurface: UIViewRepresentable {
    let controller: VLCController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // Les touchers passent à l'interface au lieu d'être captés par la vidéo
        view.isUserInteractionEnabled = false
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Écran de lecture VLC (MKV, AVI, TS…), avec les commandes communes

struct VLCPlayerView: View {
    let item: PlayItem
    var onEnded: (() -> Void)? = nil
    /// Échec de lecture (le lecteur peut alors essayer l'autre format de la chaîne)
    var onFailure: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: VLCController

    init(item: PlayItem, onEnded: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        self.item = item
        self.onEnded = onEnded
        self.onFailure = onFailure
        _controller = StateObject(wrappedValue: VLCController(url: item.url, resumeKey: item.resumeKey, startAt: item.startAt, item: item))
    }

    var body: some View {
        ControlledPlayer(
            title: item.title,
            controller: controller,
            surface: VLCVideoSurface(controller: controller).ignoresSafeArea(),
            showFailure: true,
            onClose: { dismiss() }
        )
        .onAppear { controller.start() }
        .onDisappear { controller.shutdown() }
        .onChange(of: controller.failed) {
            if controller.failed { onFailure?() }
        }
        .onChange(of: controller.ended) {
            guard controller.ended else { return }
            if let onEnded { onEnded() } else { dismiss() }
        }
    }
}
