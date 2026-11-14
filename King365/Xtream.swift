import Foundation

// MARK: - Accès à l'API Xtream Codes (player_api.php)

struct XtreamAPI {
    let host: String       // ex. http://exemple.com:8080
    let username: String
    let password: String

    init?(server: String, username: String, password: String) {
        var h = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !user.isEmpty else { return nil }
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        self.host = h
        self.username = user
        self.password = password
    }

    private func url(_ path: String, _ items: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: host + path) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ] + items
        return comps.url
    }

    var playlistURL: URL? {
        url("/get.php", [
            URLQueryItem(name: "type", value: "m3u_plus"),
            URLQueryItem(name: "output", value: "m3u8") // HLS, lisible nativement par l'iPhone
        ])
    }

    var epgURL: URL? { url("/xmltv.php") }

    /// Adresse de vérification du compte (test de connexion)
    var accountURL: URL? { url("/player_api.php") }

    func movieURL(_ movie: Movie) -> URL? {
        URL(string: "\(host)/movie/\(enc(username))/\(enc(password))/\(movie.id).\(movie.ext)")
    }

    func episodeURL(_ episode: Episode) -> URL? {
        URL(string: "\(host)/series/\(enc(username))/\(enc(password))/\(episode.id).\(episode.ext)")
    }

    private func enc(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func call<T: Decodable>(_ action: String?, _ extra: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let actionItems = action.map { [URLQueryItem(name: "action", value: $0)] } ?? []
        guard let u = url("/player_api.php", actionItems + extra) else {
            throw AppError.invalidURL
        }
        let data = try await Net.data(from: u, timeout: 90)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Infos du compte : date d'expiration, statut
    func accountInfo() async throws -> AccountInfo {
        try await call(nil, as: AccountInfo.self)
    }

    func vodCategories() async throws -> [XCategory] {
        try await call("get_vod_categories", as: [Lenient<XCategory>].self).compactMap(\.value)
    }

    func movies(category: String) async throws -> [Movie] {
        try await call("get_vod_streams", [URLQueryItem(name: "category_id", value: category)],
                       as: [Lenient<Movie>].self).compactMap(\.value)
    }

    /// Tous les films (pour la recherche vocale)
    func allMovies() async throws -> [Movie] {
        try await call("get_vod_streams", as: [Lenient<Movie>].self).compactMap(\.value)
    }

    /// Toutes les séries (pour la recherche vocale)
    func allSeries() async throws -> [SeriesItem] {
        try await call("get_series", as: [Lenient<SeriesItem>].self).compactMap(\.value)
    }

    func liveCategories() async throws -> [XCategory] {
        try await call("get_live_categories", as: [Lenient<XCategory>].self).compactMap(\.value)
    }

    /// Chaînes en direct avec leurs infos de replay
    func liveStreams() async throws -> [LiveStream] {
        try await call("get_live_streams", as: [Lenient<LiveStream>].self).compactMap(\.value)
    }

    /// Programmes passés (et à venir) d'une chaîne, avec l'indication du replay
    func archive(streamID: String) async throws -> [ArchiveProgramme] {
        try await call("get_simple_data_table", [URLQueryItem(name: "stream_id", value: streamID)],
                       as: ArchiveTable.self).listings
    }

    /// Lien de lecture d'un programme passé :
    /// /timeshift/utilisateur/motdepasse/durée-en-minutes/AAAA-MM-JJ:HH-MM/id.ts
    func replayURL(stream: LiveStream, programme: ArchiveProgramme) -> URL? {
        let minutes = max(Int(programme.stop.timeIntervalSince(programme.start) / 60), 1)
        let raw = programme.serverStart
        let start: String
        if raw.count >= 16 {
            // « 2026-11-07 18:00:00 » → « 2026-11-07:18-00 »
            let date = raw.prefix(10)
            let time = raw.dropFirst(11).prefix(5).replacingOccurrences(of: ":", with: "-")
            start = "\(date):\(time)"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd:HH-mm"
            start = f.string(from: programme.start)
        }
        return URL(string: "\(host)/timeshift/\(enc(username))/\(enc(password))/\(minutes)/\(start)/\(stream.id).ts")
    }

    func movieInfo(_ id: String) async throws -> MovieInfo {
        try await call("get_vod_info", [URLQueryItem(name: "vod_id", value: id)], as: MovieInfo.self)
    }

    func seriesCategories() async throws -> [XCategory] {
        try await call("get_series_categories", as: [Lenient<XCategory>].self).compactMap(\.value)
    }

    func series(category: String) async throws -> [SeriesItem] {
        try await call("get_series", [URLQueryItem(name: "category_id", value: category)],
                       as: [Lenient<SeriesItem>].self).compactMap(\.value)
    }

    func seriesInfo(_ id: String) async throws -> SeriesInfo {
        try await call("get_series_info", [URLQueryItem(name: "series_id", value: id)], as: SeriesInfo.self)
    }
}

// MARK: - Décodage tolérant (les serveurs Xtream mélangent textes, nombres et null)

struct Flex: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = nil }
    }
}

/// Ignore un élément mal formé au lieu de faire échouer toute la liste
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func flex(_ key: Key) -> String? {
        guard let f = try? decodeIfPresent(Flex.self, forKey: key),
              let v = f.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    func flexURL(_ key: Key) -> URL? {
        flex(key).flatMap { URL(string: $0) }
    }

    /// Image de fond : "backdrop_path" est un tableau de liens ou un simple lien selon les serveurs
    func backdropURL(_ key: Key) -> URL? {
        if let list = try? decodeIfPresent([String].self, forKey: key),
           let first = list.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return URL(string: first)
        }
        return flexURL(key)
    }
}

// MARK: - Modèles

struct AccountInfo: Decodable {
    var expiry: Date?
    var created: Date?
    var status: String?
    var username: String?
    var maxConnections: String?
    var activeConnections: String?
    var isTrial = false
    /// Le serveur a répondu mais refuse les identifiants
    var authRefused = false

    enum RootKeys: String, CodingKey { case user_info }
    enum Keys: String, CodingKey {
        case exp_date, created_at, status, username, max_connections, active_cons, is_trial, auth
    }

    init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let c = try? root.nestedContainer(keyedBy: Keys.self, forKey: .user_info) else {
            authRefused = true
            return
        }
        authRefused = c.flex(.auth) == "0"
        expiry = c.flex(.exp_date).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        created = c.flex(.created_at).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        status = c.flex(.status)
        username = c.flex(.username)
        maxConnections = c.flex(.max_connections)
        activeConnections = c.flex(.active_cons)
        isTrial = c.flex(.is_trial) == "1"
    }
}

protocol PosterItem: Identifiable, Hashable {
    var id: String { get }
    var name: String { get }
    var imageURL: URL? { get }
    var rating: String? { get }
    /// Date d'ajout chez le fournisseur (tri « Derniers ajouts »)
    var added: Date? { get }
}

struct XCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey { case id = "category_id", name = "category_name" }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flex(.id) ?? ""
        name = c.flex(.name) ?? "Sans nom"
    }

    /// Catégorie spéciale « Derniers ajouts »
    static let recent = XCategory(id: "__recent", name: "🆕 Derniers ajouts")
    var isRecent: Bool { id == Self.recent.id }
}

struct Movie: Decodable, PosterItem {
    let id: String
    let name: String
    var imageURL: URL?
    let ext: String
    let rating: String?
    let categoryID: String?
    /// Année de sortie, donnée par le serveur ou lue dans le titre « (2009) »
    let year: Int?
    /// Genre, quand le serveur l'indique dans la liste
    let genre: String?
    var added: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id = "stream_id", name, icon = "stream_icon", ext = "container_extension", rating, year, genre, added
        case categoryID = "category_id"
    }

    init(id: String, name: String, imageURL: URL?, ext: String, rating: String?,
         categoryID: String?, year: Int?, genre: String?) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.ext = ext
        self.rating = rating
        self.categoryID = categoryID
        self.year = year
        self.genre = genre
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flex(.id) ?? ""
        name = c.flex(.name) ?? "Sans titre"
        imageURL = c.flexURL(.icon)
        ext = c.flex(.ext) ?? "mp4"
        rating = c.flex(.rating)
        categoryID = c.flex(.categoryID)
        genre = c.flex(.genre)
        added = c.flex(.added).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        if let y = c.flex(.year).flatMap({ Int($0.prefix(4)) }), y > 1900 {
            year = y
        } else if let r = name.range(of: #"(19|20)\d{2}"#, options: .regularExpression) {
            year = Int(name[r])
        } else {
            year = nil
        }
    }
}

struct MovieInfo: Decodable {
    var plot: String?
    var genre: String?
    var cast: String?
    var director: String?
    var duration: String?
    var rating: String?
    var releaseDate: String?
    var cover: URL?
    var backdrop: URL?

    var year: String? { releaseDate.map { String($0.prefix(4)) } }

    enum RootKeys: String, CodingKey { case info }
    enum Keys: String, CodingKey {
        case plot, description, genre, cast, actors, director, duration, rating
        case releasedate, release_date, cover_big, movie_image, backdrop_path
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        // "info" peut être un tableau vide quand le serveur n'a rien
        guard let c = try? root.nestedContainer(keyedBy: Keys.self, forKey: .info) else { return }
        plot = c.flex(.plot) ?? c.flex(.description)
        genre = c.flex(.genre)
        cast = c.flex(.cast) ?? c.flex(.actors)
        director = c.flex(.director)
        duration = c.flex(.duration)
        rating = c.flex(.rating)
        releaseDate = c.flex(.releasedate) ?? c.flex(.release_date)
        cover = c.flexURL(.cover_big) ?? c.flexURL(.movie_image)
        backdrop = c.backdropURL(.backdrop_path)
    }
}

struct SeriesItem: Decodable, PosterItem {
    let id: String
    let name: String
    var imageURL: URL?
    let rating: String?
    let categoryID: String?
    var added: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id = "series_id", name, cover, rating
        case categoryID = "category_id"
        case lastModified = "last_modified"
    }

    init(id: String, name: String, imageURL: URL?, rating: String?, categoryID: String?) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.rating = rating
        self.categoryID = categoryID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flex(.id) ?? ""
        name = c.flex(.name) ?? "Sans titre"
        imageURL = c.flexURL(.cover)
        rating = c.flex(.rating)
        categoryID = c.flex(.categoryID)
        added = c.flex(.lastModified).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }
}

struct Episode: Decodable, Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let ext: String
    let season: Int?
    var plot: String?
    var duration: String?
    var image: URL?

    enum Keys: String, CodingKey { case id, episode_num, title, container_extension, season, info }
    enum InfoKeys: String, CodingKey { case plot, duration, movie_image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.flex(.id) ?? ""
        number = c.flex(.episode_num).flatMap { Double($0) }.map { Int($0) } ?? 0
        title = c.flex(.title) ?? "Épisode"
        ext = c.flex(.container_extension) ?? "mp4"
        season = c.flex(.season).flatMap { Double($0) }.map { Int($0) }
        if let i = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = i.flex(.plot)
            duration = i.flex(.duration)
            image = i.flexURL(.movie_image)
        }
    }
}

struct SeriesInfo: Decodable {
    var plot: String?
    var genre: String?
    var cast: String?
    var releaseDate: String?
    var rating: String?
    var cover: URL?
    var backdrop: URL?
    var seasons: [Int: [Episode]] = [:]

    var year: String? { releaseDate.map { String($0.prefix(4)) } }
    var seasonNumbers: [Int] { seasons.keys.sorted() }

    enum RootKeys: String, CodingKey { case info, episodes }
    enum InfoKeys: String, CodingKey {
        case plot, genre, cast, releaseDate, release_date, rating, cover, backdrop_path
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)

        if let c = try? root.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = c.flex(.plot)
            genre = c.flex(.genre)
            cast = c.flex(.cast)
            releaseDate = c.flex(.releaseDate) ?? c.flex(.release_date)
            rating = c.flex(.rating)
            cover = c.flexURL(.cover)
            backdrop = c.backdropURL(.backdrop_path)
        }

        // Les épisodes arrivent soit par saison {"1": [...]}, soit en tableau de tableaux
        if let dict = try? root.decode([String: [Lenient<Episode>]].self, forKey: .episodes) {
            for (key, list) in dict {
                seasons[Int(key) ?? 0, default: []] += list.compactMap(\.value)
            }
        } else if let arrays = try? root.decode([[Lenient<Episode>]].self, forKey: .episodes) {
            for list in arrays {
                for ep in list.compactMap(\.value) {
                    seasons[ep.season ?? 1, default: []].append(ep)
                }
            }
        }
        for key in seasons.keys {
            seasons[key]?.sort { $0.number < $1.number }
        }
    }
}
