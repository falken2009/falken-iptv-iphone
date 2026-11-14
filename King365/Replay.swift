import SwiftUI

// MARK: - Données du replay (Xtream « catch-up »)

struct LiveStream: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: URL?
    let archiveDays: Int
    let hasArchive: Bool
    let categoryID: String?

    enum Keys: String, CodingKey {
        case stream_id, name, stream_icon, tv_archive, tv_archive_duration, category_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.flex(.stream_id) ?? ""
        name = c.flex(.name) ?? "Chaîne"
        icon = c.flexURL(.stream_icon)
        hasArchive = c.flex(.tv_archive) == "1"
        archiveDays = c.flex(.tv_archive_duration).flatMap { Int($0) } ?? 0
        categoryID = c.flex(.category_id)
    }
}

struct ArchiveProgramme: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let desc: String?
    let start: Date
    let stop: Date
    /// Heure de début telle que le serveur l'écrit (son fuseau horaire), utilisée dans le lien de replay
    let serverStart: String
    let hasArchive: Bool

    enum Keys: String, CodingKey {
        case id, title, description, start, start_timestamp, stop_timestamp, has_archive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.flex(.id) ?? UUID().uuidString
        title = Self.decode64(c.flex(.title)) ?? "Programme"
        desc = Self.decode64(c.flex(.description))
        start = Date(timeIntervalSince1970: c.flex(.start_timestamp).flatMap { Double($0) } ?? 0)
        stop = Date(timeIntervalSince1970: c.flex(.stop_timestamp).flatMap { Double($0) } ?? 0)
        serverStart = c.flex(.start) ?? ""
        hasArchive = c.flex(.has_archive) == "1"
    }

    /// Les titres Xtream sont encodés en base64
    private static func decode64(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return value
    }
}

struct ArchiveTable: Decodable {
    var listings: [ArchiveProgramme] = []

    enum Keys: String, CodingKey { case epg_listings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        listings = ((try? c.decode([Lenient<ArchiveProgramme>].self, forKey: .epg_listings)) ?? [])
            .compactMap(\.value)
    }
}

// MARK: - Écran Replay

struct CatchUpView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var parental: ParentalStore
    @State private var streams: [LiveStream] = []
    @State private var categoryNames: [String: String] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var selected: LiveStream?

    @State private var programmes: [ArchiveProgramme] = []
    @State private var loadingProgrammes = false
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var playing: PlayItem?

    private var channels: [LiveStream] {
        let withArchive = streams.filter { stream in
            stream.hasArchive && !parental.isLocked(stream.categoryID.flatMap { categoryNames[$0] } ?? "")
        }
        return search.isEmpty ? withArchive : withArchive.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.xtream == nil {
                    XtreamRequiredView(kind: "Replay")
                } else {
                    HStack(spacing: 0) {
                        channelList
                            .frame(width: 280)
                        Rectangle()
                            .fill(.white.opacity(0.15))
                            .frame(width: 1)
                            .ignoresSafeArea()
                        programmePane
                    }
                }
            }
            .background(KingBackground(dimmed: true))
            .navigationTitle(selected?.name ?? "Replay")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Rechercher une chaîne")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
            .task { await loadStreams() }
            .task(id: selected?.id) { await loadProgrammes() }
            .fullScreenCover(item: $playing) { item in
                PlayerView(item: item)
            }
        }
    }

    // Colonne de gauche : chaînes avec replay
    private var channelList: some View {
        List(channels) { stream in
            let isOn = stream.id == selected?.id
            Button {
                selected = stream
                day = Calendar.current.startOfDay(for: .now)
            } label: {
                HStack(spacing: 10) {
                    AsyncImage(url: stream.icon) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                    }
                    .frame(width: 40, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stream.name).lineLimit(1)
                        Text("\(stream.archiveDays) j de replay")
                            .font(.caption2)
                            .foregroundStyle(isOn ? .white.opacity(0.85) : .secondary)
                    }
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isOn ? Color.kingRed.opacity(0.85) : Color.black.opacity(0.35))
        }
        .kingBackground()
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if channels.isEmpty && search.isEmpty {
                ContentUnavailableView(
                    "Pas de replay",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Aucune chaîne de ton abonnement ne propose le replay.")
                )
            }
        }
    }

    // Partie droite : jours puis programmes déjà diffusés
    @ViewBuilder
    private var programmePane: some View {
        if let stream = selected {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days(for: stream), id: \.self) { d in
                            Button {
                                day = d
                            } label: {
                                Text(dayLabel(d))
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(d == day ? Color.kingRed : Color.black.opacity(0.4), in: Capsule())
                                    .overlay(Capsule().stroke(.white.opacity(d == day ? 0.9 : 0.25), lineWidth: 1))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                let items = programmes(on: day)
                List(items) { p in
                    Button {
                        play(p, on: stream)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(p.start.formatted(date: .omitted, time: .shortened))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title).font(.headline).lineLimit(1)
                                if let d = p.desc {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text("\(Int(p.stop.timeIntervalSince(p.start) / 60)) min")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.kingRed)
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.black.opacity(0.35))
                }
                .kingBackground()
                .overlay {
                    if loadingProgrammes {
                        ProgressView()
                    } else if items.isEmpty {
                        ContentUnavailableView("Rien à revoir ce jour-là", systemImage: "calendar.badge.clock")
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Choisis une chaîne",
                systemImage: "clock.arrow.circlepath",
                description: Text("Sélectionne une chaîne à gauche pour revoir ses programmes.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Logique

    private func days(for stream: LiveStream) -> [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        let count = min(max(stream.archiveDays, 1), 14)
        return (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Aujourd'hui" }
        if Calendar.current.isDateInYesterday(date) { return "Hier" }
        return date.formatted(.dateTime.weekday(.abbreviated).day()).capitalized
    }

    private func programmes(on day: Date) -> [ArchiveProgramme] {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let now = Date()
        return programmes
            .filter { $0.start >= day && $0.start < next && $0.stop < now && $0.hasArchive }
            .sorted { $0.start > $1.start }
    }

    private func play(_ programme: ArchiveProgramme, on stream: LiveStream) {
        guard let url = store.xtream?.replayURL(stream: stream, programme: programme) else { return }
        playing = PlayItem(title: "\(stream.name) · \(programme.title)", url: url, isReplay: true)
    }

    private func loadStreams() async {
        guard streams.isEmpty, let api = store.xtream else { loading = false; return }
        defer { loading = false }
        do {
            streams = try await api.liveStreams()
            let categories = (try? await api.liveCategories()) ?? []
            categoryNames = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            error = nil
        } catch {
            self.error = Net.message(for: error)
        }
    }

    private func loadProgrammes() async {
        guard let stream = selected, let api = store.xtream else { return }
        loadingProgrammes = true
        defer { loadingProgrammes = false }
        programmes = (try? await api.archive(streamID: stream.id)) ?? []
    }
}
