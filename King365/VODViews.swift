import SwiftUI

// MARK: - Tri des films et séries

enum CatalogSort: String, CaseIterable, Identifiable {
    case az, za, recent, rating, original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .az: return "Titre de A à Z"
        case .za: return "Titre de Z à A"
        case .recent: return "Derniers ajouts"
        case .rating: return "Mieux notés"
        case .original: return "Ordre du fournisseur"
        }
    }

    var icon: String {
        switch self {
        case .az: return "arrow.down"
        case .za: return "arrow.up"
        case .recent: return "sparkles"
        case .rating: return "star"
        case .original: return "list.bullet"
        }
    }

    func apply<Item: PosterItem>(_ items: [Item]) -> [Item] {
        switch self {
        case .original:
            return items
        case .recent:
            return items.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .rating:
            return items.sorted { (Double($0.rating ?? "") ?? 0) > (Double($1.rating ?? "") ?? 0) }
        case .az, .za:
            // Clé calculée une seule fois par titre pour rester rapide sur de gros catalogues
            let keyed = items.map { (key: catalogSortKey($0.name), item: $0) }
            let ascending = self == .az
            return keyed.sorted {
                let order = $0.key.localizedStandardCompare($1.key)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            .map(\.item)
        }
    }
}

/// Titre sans le préfixe de langue (« FR - », « |FR| », « [VOSTFR] »…), sans accents ni majuscules,
/// pour que « FR - Avatar » soit classé à la lettre A.
func catalogSortKey(_ name: String) -> String {
    let s = stripCatalogPrefix(name)
    return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

/// Enlève le préfixe de langue ou de qualité en gardant les majuscules du titre
func stripCatalogPrefix(_ name: String) -> String {
    var s = name
    let prefixes = [
        #"^\s*[\[\(\|][A-Za-z0-9 ]{2,8}[\]\)\|]\s*"#,
        #"^\s*[A-Z0-9]{2,6}\s*[-:|]\s*"#
    ]
    for pattern in prefixes {
        if let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
        }
    }
    return String(s.drop { !$0.isLetter && !$0.isNumber })
}

struct SortMenu: View {
    @Binding var order: CatalogSort

    var body: some View {
        Menu {
            Picker("Trier", selection: $order) {
                ForEach(CatalogSort.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Label("Trier", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Trier")
    }
}

// MARK: - Éléments communs

struct XtreamRequiredView: View {
    let kind: String

    var body: some View {
        ContentUnavailableView(
            "\(kind) avec Xtream Codes",
            systemImage: "film.stack",
            description: Text("Connecte-toi avec tes identifiants Xtream dans Réglages pour voir les \(kind.lowercased()) de ton abonnement.")
        )
    }
}

struct PosterImage: View {
    let url: URL?
    /// Se met à jour quand TMDB trouve une jaquette de secours
    @ObservedObject private var tmdb = TmdbStore.shared

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if let url, let backup = tmdbCache.fallback(url) {
                        // Image du fournisseur cassée ou trop lente : jaquette trouvée sur TMDB
                        AsyncImage(url: backup) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                    } else {
                        ZStack {
                            Color.gray.opacity(0.2)
                            Image(systemName: "film").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PosterGrid<Item: PosterItem, Destination: View>: View {
    let items: [Item]
    @ViewBuilder let destination: (Item) -> Destination

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        destination(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            PosterImage(url: item.imageURL)
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(RotatingBackdrop(images: Array(items.prefix(20).compactMap(\.imageURL))))
    }
}

struct CategoryList<Destination: View>: View {
    let categories: [XCategory]
    let loading: Bool
    let error: String?
    @ViewBuilder let destination: (XCategory) -> Destination
    @EnvironmentObject var parental: ParentalStore
    @State private var search = ""
    @State private var askPIN = false

    private var filtered: [XCategory] {
        search.isEmpty ? categories : categories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            ForEach(filtered) { category in
                Group {
                    if parental.isLocked(category.name) {
                        Button {
                            askPIN = true
                        } label: {
                            HStack {
                                Text(category.name)
                                LockBadge(category: category.name)
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            destination(category)
                        } label: {
                            HStack {
                                Text(category.name)
                                LockBadge(category: category.name)
                            }
                        }
                    }
                }
                .lockContextMenu(category.name)
                .listRowBackground(Color.black.opacity(0.35))
            }
        }
        .kingBackground()
        .fullScreenCover(isPresented: $askPIN) {
            PINPadView(title: "Catégorie verrouillée") { parental.unlock(with: $0) }
        }
        .overlay {
            if loading && categories.isEmpty { ProgressView() }
        }
        .searchable(text: $search, prompt: "Rechercher une catégorie")
    }
}

/// Fiche : affiche + infos principales
struct InfoHeader: View {
    let title: String
    let image: URL?
    let lines: [String]
    let rating: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: image).frame(width: 130)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.bold())
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.subheadline).foregroundStyle(.secondary)
                }
                if let rating, rating != "0" {
                    Label(rating, systemImage: "star.fill")
                        .font(.subheadline)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }
}

private func message(_ error: Error) -> String {
    Net.message(for: error)
}

// MARK: - Films

struct MoviesView: View {
    @EnvironmentObject var store: PlaylistStore
    @State private var categories: [XCategory] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.xtream == nil {
                    XtreamRequiredView(kind: "Films")
                } else {
                    CategoryList(categories: categories.isEmpty ? [] : [.recent] + categories,
                                 loading: loading, error: error) { category in
                        MovieGrid(category: category)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Films")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.xtream != nil {
                        NavigationLink {
                            VoiceSearchContent()
                        } label: {
                            Image(systemName: "mic.fill")
                        }
                        .accessibilityLabel("Recherche vocale")
                    }
                }
            }
            .task(id: store.loadedAt) { await load() }
        }
    }

    private func load() async {
        guard let api = store.xtream else { return }
        loading = true
        defer { loading = false }
        do {
            categories = try await api.vodCategories()
            error = nil
        } catch {
            self.error = message(error)
        }
    }
}

struct MovieGrid: View {
    @EnvironmentObject var store: PlaylistStore
    let category: XCategory
    @State private var movies: [Movie] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @AppStorage("catalogSort") private var sort: CatalogSort = .az
    @AppStorage("groupSagas") private var groupSagas = true
    @State private var filter = MovieFilter()
    @EnvironmentObject var parental: ParentalStore
    /// Regroupe à nouveau les sagas quand TMDB apporte de nouvelles infos
    @ObservedObject private var tmdb = TmdbStore.shared
    /// Noms des catégories, pour masquer les verrouillées dans « Derniers ajouts »
    @State private var categoryNames: [String: String] = [:]

    private var filtered: [Movie] {
        let found = search.isEmpty ? movies : movies.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let kept = found.filter { filter.matches($0) && !hidden($0.categoryID) }
        // « Derniers ajouts » : toujours du plus récent au plus ancien
        return category.isRecent ? CatalogSort.recent.apply(kept) : sort.apply(kept)
    }

    private func hidden(_ id: String?) -> Bool {
        guard category.isRecent, let id, let name = categoryNames[id] else { return false }
        return parental.isLocked(name)
    }

    var body: some View {
        Group {
            if groupSagas && search.isEmpty && !category.isRecent {
                MovieEntryGrid(entries: MovieCollections.group(filtered))
            } else {
                PosterGrid(items: filtered) { movie in
                    MovieDetailView(movie: movie)
                }
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if movies.isEmpty {
                ContentUnavailableView("Aucun film", systemImage: "film")
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Rechercher un film")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FilterMenu(filter: $filter, genres: MovieFilter.genres(in: movies))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    groupSagas.toggle()
                } label: {
                    Image(systemName: groupSagas ? "square.stack.fill" : "square.stack")
                }
                .accessibilityLabel(groupSagas ? "Ne plus regrouper les sagas" : "Regrouper les sagas")
            }
            ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $sort) }
        }
        .task {
            guard movies.isEmpty, let api = store.xtream else { return }
            defer { loading = false }
            do {
                if category.isRecent {
                    let cats = CatalogCache.movieCategoryNames.isEmpty
                        ? Dictionary(((try? await api.vodCategories()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                        : CatalogCache.movieCategoryNames
                    categoryNames = cats
                    let all = CatalogCache.movies.isEmpty ? try await api.allMovies() : CatalogCache.movies
                    movies = Array(CatalogSort.recent.apply(all).prefix(300))
                } else {
                    movies = try await api.movies(category: category.id)
                }
            } catch {
                self.error = message(error)
            }
            loading = false
            // Sagas et jaquettes manquantes trouvées sur Internet (TMDB), si une clé est réglée
            await tmdb.enrichMovies(movies) { movies = $0 }
        }
    }
}

struct MovieDetailView: View {
    @EnvironmentObject var store: PlaylistStore
    let movie: Movie
    @State private var info: MovieInfo?
    @State private var playing: PlayItem?
    @State private var resume: WatchProgress.Entry?

    private var resumeKey: String { "movie-\(movie.id)" }

    private func play(from start: Double?) {
        guard let url = store.xtream?.movieURL(movie) else { return }
        playing = PlayItem(title: movie.name, url: url, resumeKey: resumeKey, startAt: start,
                           image: info?.cover ?? movie.imageURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InfoHeader(
                    title: movie.name,
                    image: info?.cover ?? movie.imageURL,
                    lines: [info?.year, info?.genre, info?.duration].compactMap { $0 },
                    rating: info?.rating ?? movie.rating
                )

                if let resume {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: resume.fraction)
                            .tint(.kingRed)
                        HStack(spacing: 12) {
                            Button {
                                play(from: resume.position)
                            } label: {
                                Label("Reprendre à \(WatchProgress.format(resume.position))", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.kingRed)
                            .foregroundStyle(.white)

                            Button {
                                play(from: nil)
                            } label: {
                                Label("Depuis le début", systemImage: "arrow.counterclockwise")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.white)
                        }
                    }
                } else {
                    Button {
                        play(from: nil)
                    } label: {
                        Label(WatchProgress.isWatched(resumeKey) ? "Revoir" : "Lecture", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.kingRed)
                    .foregroundStyle(.white)
                }


                WatchlistButton(item: WatchItem(movie: movie))

                if let plot = info?.plot {
                    Text(plot)
                }
                if let cast = info?.cast {
                    Text("Avec : \(cast)").font(.footnote).foregroundStyle(.secondary)
                }
                if let director = info?.director {
                    Text("Réalisation : \(director)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(BackdropBackground(url: info?.backdrop ?? info?.cover ?? movie.imageURL,
                                       blur: info?.backdrop == nil ? 14 : 0))
        .navigationBarTitleDisplayMode(.inline)
        .task { info = try? await store.xtream?.movieInfo(movie.id) }
        .onAppear { resume = WatchProgress.entry(for: resumeKey) }
        .fullScreenCover(item: $playing, onDismiss: {
            resume = WatchProgress.entry(for: resumeKey)
        }) { item in
            PlayerView(item: item)
        }
    }
}

// MARK: - Séries

struct SeriesView: View {
    @EnvironmentObject var store: PlaylistStore
    @State private var categories: [XCategory] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.xtream == nil {
                    XtreamRequiredView(kind: "Séries")
                } else {
                    CategoryList(categories: categories.isEmpty ? [] : [.recent] + categories,
                                 loading: loading, error: error) { category in
                        SeriesGrid(category: category)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Séries")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.xtream != nil {
                        NavigationLink {
                            VoiceSearchContent()
                        } label: {
                            Image(systemName: "mic.fill")
                        }
                        .accessibilityLabel("Recherche vocale")
                    }
                }
            }
            .task(id: store.loadedAt) { await load() }
        }
    }

    private func load() async {
        guard let api = store.xtream else { return }
        loading = true
        defer { loading = false }
        do {
            categories = try await api.seriesCategories()
            error = nil
        } catch {
            self.error = message(error)
        }
    }
}

struct SeriesGrid: View {
    @EnvironmentObject var store: PlaylistStore
    let category: XCategory
    @State private var items: [SeriesItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @AppStorage("catalogSort") private var sort: CatalogSort = .az
    @EnvironmentObject var parental: ParentalStore
    @State private var categoryNames: [String: String] = [:]
    @AppStorage("groupSagas") private var groupSagas = true

    private var filtered: [SeriesItem] {
        var found = (search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) })
            .filter { !hidden($0.categoryID) }
        // Une même série en plusieurs qualités : on ne garde que la meilleure copie
        if groupSagas { found = Duplicates.keepBest(found, name: { $0.name }) }
        // « Derniers ajouts » : toujours du plus récent au plus ancien
        return category.isRecent ? CatalogSort.recent.apply(found) : sort.apply(found)
    }

    private func hidden(_ id: String?) -> Bool {
        guard category.isRecent, let id, let name = categoryNames[id] else { return false }
        return parental.isLocked(name)
    }

    var body: some View {
        PosterGrid(items: filtered) { series in
            SeriesDetailView(series: series)
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if items.isEmpty {
                ContentUnavailableView("Aucune série", systemImage: "rectangle.stack")
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Rechercher une série")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    groupSagas.toggle()
                } label: {
                    Image(systemName: groupSagas ? "square.stack.fill" : "square.stack")
                }
                .accessibilityLabel(groupSagas ? "Afficher toutes les copies" : "Une seule copie par série")
            }
            ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $sort) }
        }
        .task {
            guard items.isEmpty, let api = store.xtream else { return }
            defer { loading = false }
            do {
                if category.isRecent {
                    let cats = CatalogCache.seriesCategoryNames.isEmpty
                        ? Dictionary(((try? await api.seriesCategories()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                        : CatalogCache.seriesCategoryNames
                    categoryNames = cats
                    let all = CatalogCache.series.isEmpty ? try await api.allSeries() : CatalogCache.series
                    items = Array(CatalogSort.recent.apply(all).prefix(300))
                } else {
                    items = try await api.series(category: category.id)
                }
            } catch {
                self.error = message(error)
            }
            loading = false
            await TmdbStore.shared.enrichSeries(items) { items = $0 }
        }
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject var store: PlaylistStore
    let series: SeriesItem
    @State private var progressTick = 0
    @State private var info: SeriesInfo?
    @State private var season: Int?
    @State private var loading = true
    @State private var error: String?
    @State private var playing: PlayItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InfoHeader(
                    title: series.name,
                    image: info?.cover ?? series.imageURL,
                    lines: [info?.year, info?.genre].compactMap { $0 },
                    rating: info?.rating ?? series.rating
                )

                WatchlistButton(item: WatchItem(series: series))
                    .frame(maxWidth: 260)

                if let plot = info?.plot {
                    Text(plot)
                }
                if let cast = info?.cast {
                    Text("Avec : \(cast)").font(.footnote).foregroundStyle(.secondary)
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else if let info, !info.seasonNumbers.isEmpty {
                    Picker("Saison", selection: $season) {
                        ForEach(info.seasonNumbers, id: \.self) { number in
                            Text(number == 0 ? "Bonus" : "Saison \(number)").tag(Optional(number))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.kingRed)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(info.seasons[season ?? -1] ?? []) { episode in
                            episodeRow(episode)
                            Divider()
                        }
                    }
                } else {
                    Text("Aucun épisode disponible.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(BackdropBackground(url: info?.backdrop ?? info?.cover ?? series.imageURL,
                                       blur: info?.backdrop == nil ? 14 : 0))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard info == nil, let api = store.xtream else { return }
            defer { loading = false }
            do {
                let loaded = try await api.seriesInfo(series.id)
                info = loaded
                season = loaded.seasonNumbers.first { $0 > 0 } ?? loaded.seasonNumbers.first
            } catch {
                self.error = message(error)
            }
        }
        .fullScreenCover(item: $playing, onDismiss: { progressTick += 1 }) { item in
            PlayerView(item: item)
        }
    }

    /// L'épisode choisi suivi des autres épisodes de la saison (lecture enchaînée)
    private func episodeQueue(startingAt episode: Episode) -> PlayItem? {
        guard let api = store.xtream else { return nil }
        let list = info?.seasons[season ?? -1] ?? [episode]
        let items: [PlayItem] = list.compactMap { e in
            guard let url = api.episodeURL(e) else { return nil }
            let key = "episode-\(e.id)"
            return PlayItem(title: "\(series.name) · \(e.title)", url: url, resumeKey: key,
                            startAt: WatchProgress.entry(for: key)?.position,
                            image: e.image ?? info?.cover ?? series.imageURL)
        }
        guard let index = list.firstIndex(of: episode), index < items.count else { return nil }
        var first = items[index]
        first.siblings = items
        first.siblingIndex = index
        first.autoNext = true
        return first
    }

    private func episodeRow(_ episode: Episode) -> some View {
        let _ = progressTick
        let key = "episode-\(episode.id)"
        let resume = WatchProgress.entry(for: key)
        let watched = WatchProgress.isWatched(key)
        return Button {
            playing = episodeQueue(startingAt: episode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(episode.number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).lineLimit(2)
                    if let duration = episode.duration {
                        Text(duration).font(.caption).foregroundStyle(.secondary)
                    }
                    if let plot = episode.plot {
                        Text(plot).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let resume {
                        HStack(spacing: 8) {
                            ProgressView(value: resume.fraction)
                                .tint(.kingRed)
                                .frame(maxWidth: 160)
                            Text("Reprendre à \(WatchProgress.format(resume.position))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if watched && resume == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.kingRed)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filtres des films (année, note, genre)

struct MovieFilter: Equatable {
    var decade: Int? = nil        // 2020, 2010, 2000 ; 1990 = avant 2000
    var minRating: Double? = nil
    var genre: String? = nil

    var isActive: Bool { decade != nil || minRating != nil || genre != nil }

    func matches(_ movie: Movie) -> Bool {
        if let decade {
            guard let year = movie.year else { return false }
            if decade == 1990 {
                if year >= 2000 { return false }
            } else if year < decade || year >= decade + 10 {
                return false
            }
        }
        if let minRating {
            guard let r = movie.rating.flatMap({ Double($0) }), r >= minRating else { return false }
        }
        if let genre {
            guard let g = movie.genre, g.localizedCaseInsensitiveContains(genre) else { return false }
        }
        return true
    }

    /// Genres présents dans la liste (quand le serveur les fournit)
    static func genres(in movies: [Movie]) -> [String] {
        var set = Set<String>()
        for m in movies {
            for part in (m.genre ?? "").split(whereSeparator: { ",/|".contains($0) }) {
                let g = part.trimmingCharacters(in: .whitespaces)
                if g.count > 1 { set.insert(g.capitalized) }
            }
        }
        return set.sorted()
    }
}

struct FilterMenu: View {
    @Binding var filter: MovieFilter
    let genres: [String]

    var body: some View {
        Menu {
            Picker("Années", selection: $filter.decade) {
                Text("Toutes les années").tag(Int?.none)
                Text("Années 2020").tag(Int?.some(2020))
                Text("Années 2010").tag(Int?.some(2010))
                Text("Années 2000").tag(Int?.some(2000))
                Text("Avant 2000").tag(Int?.some(1990))
            }
            Picker("Note", selection: $filter.minRating) {
                Text("Toutes les notes").tag(Double?.none)
                Text("5 et plus").tag(Double?.some(5))
                Text("6 et plus").tag(Double?.some(6))
                Text("7 et plus").tag(Double?.some(7))
                Text("8 et plus").tag(Double?.some(8))
            }
            if !genres.isEmpty {
                Picker("Genre", selection: $filter.genre) {
                    Text("Tous les genres").tag(String?.none)
                    ForEach(genres, id: \.self) { g in
                        Text(g).tag(String?.some(g))
                    }
                }
            }
            if filter.isActive {
                Button("Effacer les filtres", role: .destructive) { filter = MovieFilter() }
            }
        } label: {
            Image(systemName: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtrer")
    }
}
