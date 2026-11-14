import SwiftUI
import AVKit

/// Choisit le bon lecteur : celui d'Apple (AirPlay, image dans l'image) quand il sait lire le flux,
/// sinon VLC (MKV, AVI, TS…). Si le lecteur d'Apple échoue, on bascule automatiquement sur VLC.
/// Gère aussi l'épisode suivant automatique, le zapping entre chaînes et le minuteur de veille.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current: PlayItem
    @State private var useVLC: Bool
    @State private var upNext: PlayItem?
    @State private var countdown = 10
    @State private var sleepEnd: Date?
    /// Minuteur de veille choisi dans les Réglages (0 = désactivé)
    @AppStorage("sleepMinutes") private var sleepMinutes = 0
    @State private var banner: String?
    /// L'autre format de la chaîne (.ts ⇄ .m3u8) a déjà été essayé
    @State private var triedAlternate = false
    /// Les boutons de droite s'affichent et se cachent avec le menu du lecteur
    @ObservedObject private var chrome = PlayerChromeState.shared
    /// Barre d'infos de la chaîne : visible avec le menu de la vidéo, ou quelques secondes après un zapping
    @State private var infoFlash = false
    @State private var infoTick = 0
    @State private var clock = Date()

    init(item: PlayItem) {
        let start = item.preferredFormat
        _current = State(initialValue: start)
        _useVLC = State(initialValue: start.needsVLC)
    }

    private var canZap: Bool { !current.autoNext && current.siblings.count > 1 }

    private func sibling(at index: Int) -> PlayItem {
        var item = current.siblings[index]
        item.siblings = current.siblings
        item.siblingIndex = index
        item.autoNext = current.autoNext
        return item
    }

    private var nextItem: PlayItem? {
        guard current.autoNext, current.siblingIndex + 1 < current.siblings.count else { return nil }
        return sibling(at: current.siblingIndex + 1)
    }

    var body: some View {
        ZStack {
            Group {
                if useVLC {
                    VLCPlayerView(item: current, onEnded: handleEnded, onFailure: tryAlternateFormat)
                } else {
                    ApplePlayerView(item: current, onFailure: {
                        VLCMemory.remember(current.url)
                        useVLC = true
                    }, onEnded: handleEnded)
                }
            }
            .id(current.id)

            // Commandes à droite : zapping et minuteur de veille
            HStack {
                Spacer()
                VStack(spacing: 14) {
                    if canZap {
                        sideButton("chevron.up", label: "Chaîne précédente") { zap(-1) }
                    }
                    if canZap {
                        sideButton("chevron.down", label: "Chaîne suivante") { zap(1) }
                    }
                    if current.isReplay {
                        sideButton("goforward", label: "Avancer de 2 minutes (passer la pub)") {
                            chrome.skip(seconds: 120)
                            flash("⏭ +2 min")
                        }
                        sideButton("gobackward", label: "Reculer de 2 minutes") {
                            chrome.skip(seconds: -120)
                            flash("⏮ −2 min")
                        }
                    }
                }
                .padding(.trailing, 14)
            }
            .opacity(chrome.visible ? 1 : 0)
            .allowsHitTesting(chrome.visible)
            .animation(.easeInOut(duration: 0.25), value: chrome.visible)

            if let banner {
                VStack {
                    Text(banner)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.kingRed, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 20)
                    Spacer()
                }
                .transition(.opacity)
            }

            if current.isLive, current.epgKey != nil || current.logo != nil {
                VStack {
                    Spacer()
                    ChannelInfoBar(item: current, now: clock)
                        .padding(.horizontal, 24)
                        // Au-dessus de la barre de progression du menu de la vidéo quand il est affiché
                        .padding(.bottom, chrome.visible ? 84 : 20)
                }
                .opacity(chrome.visible || infoFlash ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: chrome.visible || infoFlash)
            }

            if let next = upNext {
                nextUpCard(next)
            }
        }
        .task(id: infoTick) {
            guard infoTick > 0 else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { infoFlash = false }
        }
        .task {
            // L'heure avance : programme en cours et progression à jour
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                clock = Date()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if sleepMinutes > 0 {
                sleepEnd = Date().addingTimeInterval(Double(sleepMinutes) * 60)
            }
        }
        .task(id: sleepEnd) {
            guard let end = sleepEnd else { return }
            try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
            if !Task.isCancelled, sleepEnd != nil { dismiss() }
        }
        .task(id: upNext?.id) {
            guard upNext != nil else { return }
            countdown = 10
            while countdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
            if !Task.isCancelled, let next = upNext { play(next) }
        }
    }

    private func sideButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(label)
    }

    private func nextUpCard(_ next: PlayItem) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Épisode suivant dans \(countdown) s")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Button {
                            play(next)
                        } label: {
                            Label("Lire maintenant", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.kingRed)
                        Button("Annuler") {
                            upNext = nil
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(width: 320)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.kingRed, lineWidth: 2))
                .padding(24)
            }
        }
    }

    private func handleEnded() {
        if let next = nextItem {
            upNext = next
        } else {
            dismiss()
        }
    }

    private func play(_ item: PlayItem) {
        let start = item.preferredFormat
        upNext = nil
        triedAlternate = false
        useVLC = start.needsVLC
        current = start
    }

    /// La chaîne ne marche pas : on essaie l'autre format proposé par le serveur (.ts ⇄ .m3u8)
    private func tryAlternateFormat() {
        guard !triedAlternate, let alt = current.alternateLiveURL else { return }
        triedAlternate = true
        let original = current.siblings.indices.contains(current.siblingIndex)
            ? current.siblings[current.siblingIndex].url : current.url
        if alt == original {
            AlternateFormatMemory.forget(original)   // l'autre format ne marchait pas non plus
        } else {
            AlternateFormatMemory.remember(original)
        }
        flash("Essai dans un autre format…")
        current = current.withURL(alt)
        useVLC = true
    }

    private func zap(_ delta: Int) {
        let count = current.siblings.count
        guard count > 1 else { return }
        jump(to: (current.siblingIndex + delta + count) % count)
    }

    private func jump(to index: Int) {
        let item = sibling(at: index)
        play(item)
        clock = Date()
        infoFlash = true
        infoTick += 1
    }

    private func flash(_ text: String) {
        withAnimation { banner = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if banner == text { withAnimation { banner = nil } }
        }
    }

    private func startSleep(minutes: Int) {
        sleepEnd = Date().addingTimeInterval(Double(minutes) * 60)
        withAnimation { banner = "Arrêt dans \(minutes) min" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { banner = nil }
        }
    }
}


/// Barre d'infos en bas du lecteur : chaîne, programme en cours (horaires, progression, résumé) et suivant
struct ChannelInfoBar: View {
    let item: PlayItem
    let now: Date

    private var schedule: [Programme] {
        guard let key = item.epgKey else { return [] }
        return EPGStore.shared?.programmes(forKey: key) ?? []
    }

    var body: some View {
        let list = schedule
        let current = list.first { $0.isOn(at: now) }
        let next = list.first { $0.start >= (current?.stop ?? now) }
        HStack(alignment: .center, spacing: 14) {
            if let logo = item.logo {
                AsyncImage(url: logo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 70, height: 46)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let p = current {
                    Text("\(hour(p.start)) – \(hour(p.stop))   \(p.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ProgressView(value: p.progress(at: now))
                        .tint(.kingRed)
                    if let desc = p.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text("Pas de programme disponible pour cette chaîne")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let n = next {
                    Text("Ensuite à \(hour(n.start)) : \(n.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.kingRed.opacity(0.6), lineWidth: 1))
    }

    private func hour(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}
