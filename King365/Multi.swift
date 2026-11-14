import SwiftUI
import AVFoundation
import VLCKitSPM

// MARK: - Multi-écran : 2 ou 4 chaînes en même temps

/// Une case du multi-écran
struct MultiSlot: Identifiable {
    let id: Int
    var channel: Channel?
}

struct MultiScreenView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var parental: ParentalStore
    @State private var layout = 4
    @State private var slots = (0..<4).map { MultiSlot(id: $0) }
    @State private var audioSlot = 0
    @State private var picking: Int?
    @State private var fullScreen: PlayItem?

    private var visible: [MultiSlot] { Array(slots.prefix(layout)) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let columns = 2
                let rows = layout == 4 ? 2 : 1
                let spacing: CGFloat = 6
                let w = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let h = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(visible) { slot in
                        slotView(slot)
                            .frame(width: w, height: h)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(6)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Multi-écran")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { HomeButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Disposition", selection: $layout) {
                        Image(systemName: "rectangle.split.2x1").tag(2)
                        Image(systemName: "rectangle.split.2x2").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
            }
            .onChange(of: layout) {
                if audioSlot >= layout { audioSlot = 0 }
            }
            .sheet(item: Binding(
                get: { picking.map { PickTarget(id: $0) } },
                set: { picking = $0?.id }
            )) { target in
                ChannelPicker { channel in
                    slots[target.id].channel = channel
                    audioSlot = target.id
                    picking = nil
                }
                .environmentObject(store)
                .environmentObject(parental)
            }
            .fullScreenCover(item: $fullScreen) { item in
                PlayerView(item: item)
            }
        }
    }

    @ViewBuilder
    private func slotView(_ slot: MultiSlot) -> some View {
        if let channel = slot.channel {
            ZStack(alignment: .bottomLeading) {
                SlotPlayer(url: channel.url, muted: audioSlot != slot.id)
                    .id(channel.url)

                HStack(spacing: 6) {
                    Image(systemName: audioSlot == slot.id ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Text(channel.name).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(audioSlot == slot.id ? Color.kingRed : .white.opacity(0.2),
                            lineWidth: audioSlot == slot.id ? 3 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                fullScreen = PlayItem(title: channel.name, url: channel.url, epgKey: channel.epgKey, logo: channel.logo)
            }
            .onTapGesture { audioSlot = slot.id }
            .contextMenu {
                Button { audioSlot = slot.id } label: { Label("Écouter cette chaîne", systemImage: "speaker.wave.2") }
                Button { picking = slot.id } label: { Label("Changer de chaîne", systemImage: "arrow.triangle.2.circlepath") }
                Button { fullScreen = PlayItem(title: channel.name, url: channel.url, epgKey: channel.epgKey, logo: channel.logo) } label: {
                    Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(role: .destructive) { slots[slot.id].channel = nil } label: {
                    Label("Fermer", systemImage: "xmark")
                }
            }
        } else {
            Button {
                picking = slot.id
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 34, weight: .light))
                    Text("Ajouter une chaîne").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(RedTileStyle(cornerRadius: 8, lineWidth: 1.5))
            }
            .buttonStyle(TileButtonStyle())
        }
    }
}

private struct PickTarget: Identifiable {
    let id: Int
}

/// Choix d'une chaîne pour une case du multi-écran
struct ChannelPicker: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var parental: ParentalStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Channel) -> Void
    @State private var search = ""
    @State private var group: String?

    private var shown: [Channel] {
        let base = search.isEmpty ? (store.byGroup[group ?? store.groups.first ?? ""] ?? []) : store.search(search)
        return base.filter { !parental.isLocked($0.group) }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                List(store.groups.filter { !parental.isLocked($0) }, id: \.self) { g in
                    let isOn = search.isEmpty && g == (group ?? store.groups.first)
                    Button {
                        group = g
                        search = ""
                    } label: {
                        Text(g).lineLimit(1).foregroundStyle(.white)
                    }
                    .listRowBackground(isOn ? Color.kingRed.opacity(0.85) : Color.black.opacity(0.35))
                }
                .kingBackground()
                .frame(width: 230)

                List(shown) { channel in
                    Button {
                        onPick(channel)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            AsyncImage(url: channel.logo) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Image(systemName: "tv").foregroundStyle(.secondary)
                            }
                            .frame(width: 44, height: 28)
                            Text(channel.name).foregroundStyle(.white)
                        }
                    }
                    .listRowBackground(Color.black.opacity(0.35))
                }
                .kingBackground()
            }
            .navigationTitle("Choisis une chaîne")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Rechercher une chaîne")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
    }
}

// MARK: - Petit lecteur sans commandes (une case)

/// Utilise le lecteur d'Apple quand c'est possible, sinon VLC
struct SlotPlayer: View {
    let url: URL
    let muted: Bool

    private var needsVLC: Bool { PlayItem(title: "", url: url).needsVLC }

    var body: some View {
        if needsVLC {
            VLCSlotPlayer(url: url, muted: muted)
        } else {
            AppleSlotPlayer(url: url, muted: muted)
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct AppleLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

struct AppleSlotPlayer: View {
    let url: URL
    let muted: Bool
    @State private var player: AVPlayer
    @State private var useVLC = false

    init(url: URL, muted: Bool) {
        self.url = url
        self.muted = muted
        _player = State(initialValue: AVPlayer(playerItem: AVPlayerItem(asset: Net.asset(url))))
    }

    var body: some View {
        Group {
            if useVLC {
                VLCSlotPlayer(url: url, muted: muted)
            } else {
                AppleLayer(player: player)
                    .onAppear {
                        player.isMuted = muted
                        player.play()
                    }
                    .onDisappear { player.pause() }
                    .onChange(of: muted) { player.isMuted = muted }
                    .task {
                        // Bascule sur VLC si le lecteur d'Apple n'y arrive pas
                        while !Task.isCancelled {
                            if player.currentItem?.status == .failed {
                                player.pause()
                                useVLC = true
                                break
                            }
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
            }
        }
    }
}

struct VLCSlotPlayer: View {
    let muted: Bool
    @StateObject private var controller: VLCController

    init(url: URL, muted: Bool) {
        self.muted = muted
        _controller = StateObject(wrappedValue: VLCController(url: url, muted: muted))
    }

    var body: some View {
        VLCVideoSurface(controller: controller)
            .overlay {
                if controller.buffering { ProgressView().tint(.white) }
            }
            .onAppear {
                controller.start()
                controller.setMuted(muted)
            }
            .onDisappear { controller.shutdown() }
            .onChange(of: muted) { controller.setMuted(muted) }
    }
}
