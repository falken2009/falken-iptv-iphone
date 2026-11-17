import SwiftUI
import UserNotifications

// MARK: - Rappels de programmes (notification 5 minutes avant)

struct Reminder: Codable, Identifiable, Hashable {
    let id: String
    let channelName: String
    let channelURL: URL
    let title: String
    let start: Date
}

@MainActor
final class ReminderStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var reminders: [Reminder] = []
    /// Chaîne à ouvrir après avoir touché une notification
    @Published var pending: PlayItem?
    @Published var error: String?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "reminders"),
           let list = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = list.filter { $0.start > Date() }
        }
        UNUserNotificationCenter.current().delegate = self
    }

    static func reminderID(_ programme: Programme, _ channel: Channel) -> String {
        "\(channel.key)|\(Int(programme.start.timeIntervalSince1970))"
    }

    func has(_ programme: Programme, on channel: Channel) -> Bool {
        let id = Self.reminderID(programme, channel)
        return reminders.contains { $0.id == id }
    }

    func toggle(_ programme: Programme, on channel: Channel) async {
        let id = Self.reminderID(programme, channel)
        let center = UNUserNotificationCenter.current()

        if reminders.contains(where: { $0.id == id }) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            reminders.removeAll { $0.id == id }
            save()
            return
        }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            error = "Autorise les notifications pour Falken IPTV dans les Réglages de l'iPhone."
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Bientôt sur \(channel.name)"
        content.body = "\(programme.title) commence à \(programme.start.formatted(date: .omitted, time: .shortened))."
        content.sound = .default
        content.userInfo = ["url": channel.url.absoluteString, "name": channel.name]

        let fire = max(programme.start.addingTimeInterval(-5 * 60), Date().addingTimeInterval(5))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            reminders.append(Reminder(id: id, channelName: channel.name, channelURL: channel.url,
                                      title: programme.title, start: programme.start))
            save()
            error = nil
        } catch {
            self.error = "Impossible de programmer le rappel."
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: "reminders")
        }
    }

    // Notification touchée : on ouvre la chaîne
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let urlString = info["url"] as? String
        let name = info["name"] as? String ?? "Chaîne"
        Task { @MainActor in
            if let urlString, let url = URL(string: urlString) {
                self.pending = PlayItem(title: name, url: url)
            }
        }
        completionHandler()
    }

    // Affiche aussi la notification quand l'appli est ouverte
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Grille du guide : chaînes en lignes, heures en colonnes

private struct GuideSelection: Identifiable {
    let programme: Programme
    let channel: Channel
    var id: String { programme.id }
}

struct GuideGridView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @EnvironmentObject var parental: ParentalStore
    @EnvironmentObject var reminders: ReminderStore
    @State private var group: String?
    @State private var windowStart = GuideGridView.roundedNow()
    @State private var selection: GuideSelection?
    @State private var playing: PlayItem?

    private let hours: Double = 3
    private let channelWidth: CGFloat = 150
    private let rowHeight: CGFloat = 52

    private var windowEnd: Date { windowStart.addingTimeInterval(hours * 3600) }
    private var currentGroup: String? { group ?? store.groups.first }

    private var channels: [Channel] {
        (currentGroup.flatMap { store.byGroup[$0] } ?? []).filter { !parental.isLocked($0.group) }
    }

    static func roundedNow() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        comps.minute = (comps.minute ?? 0) < 30 ? 0 : 30
        return cal.date(from: comps) ?? Date()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                if epg.programmes.isEmpty {
                    ContentUnavailableView(
                        "Guide vide",
                        systemImage: "calendar",
                        description: Text("Touche ↻ en haut à droite pour charger le guide.")
                    )
                } else {
                    GeometryReader { geo in
                        let gridWidth = max(geo.size.width - channelWidth, 200)
                        let perMinute = gridWidth / (hours * 60)
                        TimelineView(.everyMinute) { context in
                            ScrollView {
                                LazyVStack(spacing: 3, pinnedViews: [.sectionHeaders]) {
                                    Section {
                                        ForEach(channels) { channel in
                                            row(channel, perMinute: perMinute, gridWidth: gridWidth, now: context.date)
                                        }
                                    } header: {
                                        ruler(perMinute: perMinute, gridWidth: gridWidth)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .background(KingBackground(dimmed: true))
            .navigationTitle("Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { HomeButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    if epg.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await epg.reload(store: store) }
                        } label: {
                            Label("Recharger le guide", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await epg.refreshIfNeeded(store: store) }
            .confirmationDialog(
                selection?.programme.title ?? "",
                isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
                titleVisibility: .visible,
                presenting: selection
            ) { sel in
                Button("Regarder \(sel.channel.name)") { play(sel.channel) }
                if sel.programme.start > Date() {
                    Button(reminders.has(sel.programme, on: sel.channel) ? "Annuler le rappel" : "Me rappeler 5 min avant") {
                        Task { await reminders.toggle(sel.programme, on: sel.channel) }
                    }
                }
                Button("Fermer", role: .cancel) {}
            } message: { sel in
                Text("\(timeRange(sel.programme))\n\(sel.programme.desc ?? "")")
            }
            .alert("Rappel", isPresented: Binding(get: { reminders.error != nil }, set: { if !$0 { reminders.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reminders.error ?? "")
            }
            .fullScreenCover(item: $playing) { item in
                PlayerView(item: item)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(store.groups, id: \.self) { g in
                    Button(g) { group = g }
                }
            } label: {
                Label(currentGroup ?? "Catégorie", systemImage: "list.bullet")
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            Spacer()
            Button {
                windowStart = max(windowStart.addingTimeInterval(-3600), Self.roundedNow().addingTimeInterval(-3600))
            } label: {
                Image(systemName: "chevron.left")
            }
            Button("Maintenant") { windowStart = Self.roundedNow() }
                .font(.subheadline.weight(.semibold))
            Button {
                windowStart = min(windowStart.addingTimeInterval(3600), Self.roundedNow().addingTimeInterval(30 * 3600))
            } label: {
                Image(systemName: "chevron.right")
            }
            Text(windowStart.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func ruler(perMinute: CGFloat, gridWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: channelWidth, height: 22)
            ZStack(alignment: .leading) {
                ForEach(0..<Int(hours * 2), id: \.self) { i in
                    Text(windowStart.addingTimeInterval(Double(i) * 1800).formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .offset(x: CGFloat(i) * 30 * perMinute + 4)
                }
            }
            .frame(width: gridWidth, height: 22, alignment: .leading)
        }
        .background(Color.black.opacity(0.85))
    }

    private func row(_ channel: Channel, perMinute: CGFloat, gridWidth: CGFloat, now: Date) -> some View {
        let items = epg.schedule(for: channel, from: windowStart).filter { $0.start < windowEnd }
        return HStack(spacing: 0) {
            Button {
                play(channel)
            } label: {
                HStack(spacing: 6) {
                    AsyncImage(url: channel.logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                    }
                    .frame(width: 38, height: 26)
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(width: channelWidth, height: rowHeight)
                .background(Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)

            ZStack(alignment: .leading) {
                ForEach(items) { p in
                    let start = max(p.start, windowStart)
                    let end = min(p.stop, windowEnd)
                    let x = CGFloat(start.timeIntervalSince(windowStart) / 60) * perMinute
                    let w = max(CGFloat(end.timeIntervalSince(start) / 60) * perMinute - 2, 4)
                    Button {
                        selection = GuideSelection(programme: p, channel: channel)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                if reminders.has(p, on: channel) {
                                    Image(systemName: "bell.fill").font(.caption2)
                                }
                                Text(p.title).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            Text(p.start.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(width: w, height: rowHeight - 4, alignment: .leading)
                        .background(p.isOn(at: now) ? Color.kingRed.opacity(0.75) : Color.black.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .offset(x: x)
                }
                if now >= windowStart && now < windowEnd {
                    Rectangle()
                        .fill(Color.kingRed)
                        .frame(width: 2, height: rowHeight)
                        .offset(x: CGFloat(now.timeIntervalSince(windowStart) / 60) * perMinute)
                }
            }
            .frame(width: gridWidth, height: rowHeight, alignment: .leading)
            .clipped()
        }
    }

    private func timeRange(_ p: Programme) -> String {
        p.start.formatted(date: .omitted, time: .shortened) + " – " + p.stop.formatted(date: .omitted, time: .shortened)
    }

    private func play(_ channel: Channel) {
        let list = channels
        let siblings = list.map { PlayItem(title: $0.name, url: $0.url, epgKey: $0.epgKey, logo: $0.logo) }
        let index = list.firstIndex { $0.id == channel.id } ?? 0
        playing = PlayItem(title: channel.name, url: channel.url, siblings: siblings, siblingIndex: index,
                           epgKey: channel.epgKey, logo: channel.logo)
    }
}

// MARK: - À voir plus tard

struct WatchlistView: View {
    @EnvironmentObject var store: PlaylistStore
    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    @ViewBuilder
    private func section(_ title: String, _ items: [WatchItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) (\(items.count))").font(.headline)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in card(item) }
                }
            }
        }
    }

    private func card(_ item: WatchItem) -> some View {
        NavigationLink {
            switch item.kind {
            case .movie: MovieDetailView(movie: item.movie)
            case .series: SeriesDetailView(series: item.series)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PosterImage(url: item.image)
                Text(item.name).font(.caption).lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.toggleWatchlist(item)
            } label: {
                Label("Retirer de ma liste", systemImage: "bookmark.slash")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.watchlist.isEmpty {
                    ContentUnavailableView(
                        "Ta liste est vide",
                        systemImage: "bookmark",
                        description: Text("Sur la fiche d'un film ou d'une série, touche « Ma liste » pour l'ajouter ici.")
                    )
                } else {
                    ScrollView {
                        // Films et séries séparés, chacun sous son titre
                        VStack(alignment: .leading, spacing: 22) {
                            section("Films", store.watchlist.filter { $0.kind == .movie })
                            section("Séries", store.watchlist.filter { $0.kind == .series })
                        }
                        .padding()
                    }
                }
            }
            .background(KingBackground(dimmed: true))
            .navigationTitle("Ma liste")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

extension WatchItem {
    var movie: Movie {
        Movie(id: itemID, name: name, imageURL: image, ext: ext ?? "mp4", rating: rating,
              categoryID: categoryID, year: year, genre: nil)
    }

    var series: SeriesItem {
        SeriesItem(id: itemID, name: name, imageURL: image, rating: rating, categoryID: categoryID)
    }

    init(movie: Movie) {
        self.init(id: "movie-\(movie.id)", kind: .movie, itemID: movie.id, name: movie.name, image: movie.imageURL,
                  rating: movie.rating, ext: movie.ext, categoryID: movie.categoryID, year: movie.year)
    }

    init(series: SeriesItem) {
        self.init(id: "series-\(series.id)", kind: .series, itemID: series.id, name: series.name, image: series.imageURL,
                  rating: series.rating, ext: nil, categoryID: series.categoryID, year: nil)
    }
}

/// Bouton « Ma liste » des fiches film et série
struct WatchlistButton: View {
    @EnvironmentObject var store: PlaylistStore
    let item: WatchItem

    var body: some View {
        let added = store.inWatchlist(item.id)
        Button {
            store.toggleWatchlist(item)
        } label: {
            Label(added ? "Dans ma liste" : "Ma liste", systemImage: added ? "checkmark" : "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(added ? .green : .white)
    }
}
