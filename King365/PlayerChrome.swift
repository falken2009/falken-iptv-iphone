import SwiftUI
import Combine
import AVKit
import AVFoundation

// MARK: - Commandes vidéo communes (lecteur d'Apple et VLC)

/// Ce que l'interface de lecture sait piloter, quel que soit le lecteur
@MainActor
protocol PlaybackControlling: ObservableObject {
    var isPlaying: Bool { get }
    var buffering: Bool { get }
    var failed: Bool { get }
    var ended: Bool { get }
    var hasLength: Bool { get }
    var position: Double { get }
    var timeText: String { get }
    var lengthText: String { get }
    var audioTracks: [MediaTrack] { get }
    var subtitles: [MediaTrack] { get }
    var currentAudio: Int32 { get }
    var currentSubtitle: Int32 { get }

    func togglePlay()
    func seek(to value: Double)
    func jump(seconds: Int32)
    func selectAudio(_ id: Int32)
    func selectSubtitle(_ id: Int32)
}

extension VLCController: PlaybackControlling {}

/// Visibilité du menu du lecteur, partagée avec les boutons de zapping et le micro
@MainActor
final class PlayerChromeState: ObservableObject {
    static let shared = PlayerChromeState()
    @Published var visible = true
    /// Saut demandé par les boutons du replay (passer la pub)
    @Published private(set) var skipCount = 0
    private(set) var skipSeconds: Int32 = 0

    func skip(seconds: Int32) {
        skipSeconds = seconds
        skipCount += 1
    }
}

/// Écran de lecture : un toucher affiche le menu (fermer, titre, langues, sous-titres, AirPlay,
/// lecture/pause, avance/retour, barre de progression), qui se cache tout seul après 4 secondes.
struct ControlledPlayer<C: PlaybackControlling, Surface: View>: View {
    let title: String
    @ObservedObject var controller: C
    let surface: Surface
    var showFailure = true
    let onClose: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            surface

            // Zone tactile par-dessus la vidéo : un toucher affiche ou cache le menu
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if controller.buffering && !controller.failed {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if showFailure && controller.failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Impossible de lire « \(title) ».")
                    Text("La chaîne est peut-être hors ligne, ou tous tes écrans sont utilisés\n(vérifie dans Réglages → Tester la connexion).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Fermer", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .tint(.kingRed)
                        .padding(.top, 6)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            }

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onChange(of: showControls) { _, visible in
            PlayerChromeState.shared.visible = visible
        }
        .onReceive(PlayerChromeState.shared.$skipCount.dropFirst()) { _ in
            controller.jump(seconds: PlayerChromeState.shared.skipSeconds)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            PlayerChromeState.shared.visible = showControls
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            VStack {
                // Haut : fermer, titre, langues, sous-titres, AirPlay
                HStack(spacing: 18) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Fermer la vidéo")
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if controller.audioTracks.count > 1 {
                        trackMenu("Langue", icon: "speaker.wave.2.fill",
                                  tracks: controller.audioTracks, current: controller.currentAudio) {
                            controller.selectAudio($0)
                        }
                    }
                    if !controller.subtitles.isEmpty {
                        trackMenu("Sous-titres", icon: "captions.bubble.fill",
                                  tracks: controller.subtitles, current: controller.currentSubtitle) {
                            controller.selectSubtitle($0)
                        }
                    }
                    AirPlayButton()
                        .frame(width: 36, height: 36)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                Spacer()

                // Centre : reculer, lecture/pause, avancer
                HStack(spacing: 60) {
                    if controller.hasLength {
                        Button { controller.jump(seconds: -10); scheduleHide() } label: {
                            Image(systemName: "gobackward.10").font(.system(size: 34))
                        }
                    }
                    Button { controller.togglePlay(); scheduleHide() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52))
                    }
                    if controller.hasLength {
                        Button { controller.jump(seconds: 30); scheduleHide() } label: {
                            Image(systemName: "goforward.30").font(.system(size: 34))
                        }
                    }
                }

                Spacer()

                // Bas : barre de progression (films et épisodes) ou « EN DIRECT »
                if controller.hasLength {
                    HStack(spacing: 12) {
                        Text(controller.timeText).monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { dragging ? dragValue : controller.position },
                                set: { dragValue = $0 }
                            ),
                            in: 0...1,
                            onEditingChanged: { editing in
                                if editing {
                                    dragValue = controller.position
                                    hideTask?.cancel()
                                } else {
                                    controller.seek(to: dragValue)
                                    scheduleHide()
                                }
                                dragging = editing
                            }
                        )
                        .tint(.kingRed)
                        Text(controller.lengthText).monospacedDigit()
                    }
                    .font(.footnote)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                } else {
                    Text("EN DIRECT")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.kingRed, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func trackMenu(_ title: String, icon: String, tracks: [MediaTrack], current: Int32,
                           select: @escaping (Int32) -> Void) -> some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    select(track.id)
                    scheduleHide()
                } label: {
                    if track.id == current {
                        Label(track.name, systemImage: "checkmark")
                    } else {
                        Text(track.name)
                    }
                }
            }
        } label: {
            Image(systemName: icon).font(.title2)
        }
        .accessibilityLabel(title)
    }

    private func toggleControls() {
        withAnimation { showControls.toggle() }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, controller.isPlaying, !dragging {
                withAnimation { showControls = false }
            }
        }
    }
}

/// Bouton AirPlay du système
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemRed
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Lecteur d'Apple (HLS, MP4) avec les mêmes commandes

final class AVPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AVPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVPlayerLayerView {
        let view = AVPlayerLayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: AVPlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

@MainActor
final class AppleController: ObservableObject, PlaybackControlling {
    let player: AVPlayer
    private let item: PlayItem

    @Published private(set) var isPlaying = false
    @Published private(set) var buffering = true
    @Published private(set) var failed = false
    @Published private(set) var ended = false
    @Published private(set) var hasLength = false
    @Published private(set) var position: Double = 0
    @Published private(set) var timeText = "0:00"
    @Published private(set) var lengthText = ""
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitles: [MediaTrack] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1

    private var poll: Task<Void, Never>?
    private var ticks = 0
    private var tracksLoaded = false
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    /// Pause demandée par l'utilisateur (sinon on relance tout seul)
    private var userPaused = false
    private var everPlayed = false
    private var startedAt = Date()
    private var stalledSince: Date?

    init(item: PlayItem) {
        self.item = item
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: Net.asset(item.url)))
    }

    func start() {
        if let start = item.startAt {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        player.play()
        startedAt = Date()
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
        player.pause()
        // Ferme vraiment la connexion : beaucoup d'abonnements n'autorisent qu'un écran à la fois,
        // et une connexion restée ouverte bloquerait la chaîne suivante (rond qui tourne sans fin)
        (player.currentItem?.asset as? AVURLAsset)?.cancelLoading()
        player.replaceCurrentItem(with: nil)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            player.play()
        }
        refresh()
    }

    func seek(to value: Double) {
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(max(value, 0), 1) * duration, preferredTimescale: 600))
    }

    func jump(seconds: Int32) {
        let target = player.currentTime().seconds + Double(seconds)
        player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
    }

    func selectAudio(_ id: Int32) {
        guard let group = audioGroup, id >= 0, Int(id) < group.options.count else { return }
        player.currentItem?.select(group.options[Int(id)], in: group)
        currentAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        guard let group = subtitleGroup else { return }
        if id < 0 || Int(id) >= group.options.count {
            player.currentItem?.select(nil, in: group)
            currentSubtitle = -1
        } else {
            player.currentItem?.select(group.options[Int(id)], in: group)
            currentSubtitle = id
        }
    }

    private func refresh() {
        guard let current = player.currentItem else { return }
        isPlaying = player.timeControlStatus == .playing
        buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if current.status == .failed { failed = true }

        let duration = current.duration.seconds
        let time = player.currentTime().seconds
        hasLength = duration.isFinite && duration > 0
        watchdog(current)
        if hasLength {
            position = time.isFinite ? time / duration : 0
            lengthText = Self.format(duration)
            // Fin de la vidéo
            if time >= duration - 0.5 && !isPlaying && !ended { ended = true }
        }
        timeText = Self.format(time.isFinite ? time : 0)

        if current.status == .readyToPlay && !tracksLoaded {
            tracksLoaded = true
            Task { await loadTracks(current.asset) }
        }

        ticks += 1
        if ticks % 10 == 0 { saveProgress() }
    }

    /// Évite les chaînes bloquées sur pause :
    /// - le flux ne démarre pas en 12 s → on passe sur VLC ;
    /// - le direct s'arrête tout seul (coupure réseau) → on relance la lecture ;
    /// - le direct reste figé plus de 15 s → on passe sur VLC.
    private func watchdog(_ current: AVPlayerItem) {
        guard !failed, !ended else { return }
        if isPlaying {
            everPlayed = true
            stalledSince = nil
            return
        }
        if !everPlayed {
            // Pas encore démarré et pas de pause demandée : on insiste
            if !userPaused && player.timeControlStatus == .paused { player.play() }
            // Démarrage plus rapide : dès 3 secondes de vidéo reçues, on lance la lecture
            // au lieu d'attendre que le lecteur d'Apple juge la réserve « suffisante »
            if !userPaused, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
               let range = current.loadedTimeRanges.first?.timeRangeValue {
                let ahead = range.end.seconds - player.currentTime().seconds
                if ahead.isFinite && ahead >= 3 { player.playImmediately(atRate: 1) }
            }
            // Rien ne s'affiche : VLC prend le relais. On attend plus longtemps si les données arrivent
            // (serveur lent mais qui répond) que si rien n'arrive du tout (format illisible).
            let receiving = !current.loadedTimeRanges.isEmpty || current.status == .readyToPlay
            let limit: TimeInterval = receiving ? 20 : 10
            if !userPaused && Date().timeIntervalSince(startedAt) > limit { failed = true }
            return
        }
        guard !userPaused, !hasLength else { return }
        if player.timeControlStatus == .paused {
            player.play()
        }
        if stalledSince == nil { stalledSince = Date() }
        if let since = stalledSince, Date().timeIntervalSince(since) > 15 { failed = true }
    }

    private func loadTracks(_ asset: AVAsset) async {
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = group
            audioTracks = group.options.enumerated().map { MediaTrack(id: Int32($0.offset), name: $0.element.displayName) }
            if let selected = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                currentAudio = Int32(index)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible), !group.options.isEmpty {
            subtitleGroup = group
            subtitles = [MediaTrack(id: -1, name: "Désactivés")]
                + group.options.enumerated().map { MediaTrack(id: Int32($0.offset), name: $0.element.displayName) }
        }
    }

    private func saveProgress() {
        guard item.resumeKey != nil, let current = player.currentItem else { return }
        WatchProgress.save(item: item, position: player.currentTime().seconds, duration: current.duration.seconds)
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Lecteur d'Apple avec les commandes Falken ; bascule sur VLC s'il ne sait pas lire le flux
struct ApplePlayerView: View {
    let item: PlayItem
    let onFailure: () -> Void
    var onEnded: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: AppleController

    init(item: PlayItem, onFailure: @escaping () -> Void, onEnded: (() -> Void)? = nil) {
        self.item = item
        self.onFailure = onFailure
        self.onEnded = onEnded
        _controller = StateObject(wrappedValue: AppleController(item: item))
    }

    var body: some View {
        ControlledPlayer(
            title: item.title,
            controller: controller,
            surface: AVPlayerSurface(player: controller.player).ignoresSafeArea(),
            showFailure: false,
            onClose: { dismiss() }
        )
        .onAppear { controller.start() }
        .onDisappear { controller.shutdown() }
        .onChange(of: controller.failed) {
            if controller.failed {
                controller.shutdown()
                onFailure()
            }
        }
        .onChange(of: controller.ended) {
            guard controller.ended else { return }
            if let onEnded { onEnded() } else { dismiss() }
        }
    }
}
