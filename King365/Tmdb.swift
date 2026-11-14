import SwiftUI

// MARK: - The Movie Database (TMDB) : sagas et jaquettes manquantes

/// Réponses TMDB gardées sur l'iPhone : chaque titre n'est cherché qu'une fois
final class TmdbCache: @unchecked Sendable {
    struct Info: Codable {
        var poster: String?
        var collectionID: Int?
        var collectionName: String?
    }

    private let lock = NSLock()
    private var entries: [String: Info] = [:]
    private var byMovieID: [String: Info] = [:]
    /// Jaquette TMDB de secours pour chaque image du fournisseur (souvent des liens cassés)
    private var fallbacks: [URL: URL] = [:]

    func setFallback(_ original: URL, _ poster: URL) { lock.withLock { fallbacks[original] = poster } }
    func fallback(_ original: URL) -> URL? { lock.withLock { fallbacks[original] } }

    private var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tmdb.json")
    }

    init() {
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Info].self, from: data) {
            entries = saved
        }
    }

    func get(_ key: String) -> Info? { lock.withLock { entries[key] } }
    func set(_ key: String, _ info: Info) { lock.withLock { entries[key] = info } }
    func setMovie(_ id: String, _ info: Info) { lock.withLock { byMovieID[id] = info } }
    func movie(_ id: String) -> Info? { lock.withLock { byMovieID[id] } }

    func save() {
        guard let file else { return }
        let snapshot = lock.withLock { entries }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file)
    }

    func clear() {
        lock.withLock {
            entries = [:]
            byMovieID = [:]
            fallbacks = [:]
        }
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}

/// Mémoire TMDB partagée (lisible depuis n'importe quel fil)
let tmdbCache = TmdbCache()

/// Cherche chaque film sur TMDB (base de films gratuite) pour savoir à quelle saga il appartient
/// et récupérer une jaquette quand le fournisseur n'en donne pas. Nécessite une clé TMDB gratuite.
@MainActor
final class TmdbStore: ObservableObject {
    static let shared = TmdbStore()

    /// Change à chaque nouvelle information : les écrans regroupent à nouveau les sagas
    @Published private(set) var version = 0

    nonisolated var cache: TmdbCache { tmdbCache }
    private static let maxPerList = 600

    nonisolated static var key: String {
        (UserDefaults.standard.string(forKey: "tmdbKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var enabled: Bool { !Self.key.isEmpty }

    nonisolated private static func movieKey(_ m: Movie) -> String {
        "m|" + Duplicates.key(m.name) + "|" + (m.year.map(String.init) ?? "")
    }

    nonisolated private static func seriesKey(_ s: SeriesItem) -> String { "s|" + Duplicates.key(s.name) }

    /// Saga d'un film d'après TMDB : (clé de regroupement, nom affiché)
    nonisolated static func collection(for movie: Movie) -> (key: String, name: String)? {
        let info = tmdbCache.movie(movie.id) ?? tmdbCache.get(movieKey(movie))
        guard let id = info?.collectionID else { return nil }
        return ("tmdb:\(id)", info?.collectionName ?? movie.name)
    }

    /// « Deadpool - Saga », « Harry Potter : La Collection » → « Deadpool », « Harry Potter »
    nonisolated private static func cleanCollection(_ name: String) -> String {
        var s = name.replacingOccurrences(
            of: #"(?i)\s*[-–:(]?\s*(la\s+)?(saga|collection|trilogie|trilogy)\)?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^(saga|collection)\s+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? name : s
    }

    nonisolated private static func get(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        let key = Self.key
        let bearer = key.count > 40       // jeton d'accès en lecture (long) ou clé API (32 caractères)
        var comps = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 15
        if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetError.http(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    nonisolated private static func image(_ path: Any?) -> String? {
        guard let p = path as? String, !p.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/w342" + p
    }

    nonisolated private func lookup(_ m: Movie) async throws -> TmdbCache.Info {
        let key = Self.movieKey(m)
        if let known = cache.get(key) { return known }
        var params = ["query": Duplicates.key(m.name), "language": "fr-FR", "include_adult": "false"]
        if let y = m.year { params["year"] = String(y) }
        var results = try await Self.get("/search/movie", params)["results"] as? [[String: Any]] ?? []
        if results.isEmpty, m.year != nil {
            // L'année du fournisseur est parfois fausse : nouvel essai sans elle
            params["year"] = nil
            results = try await Self.get("/search/movie", params)["results"] as? [[String: Any]] ?? []
        }
        var info = TmdbCache.Info()
        if let first = results.first, let id = first["id"] as? Int {
            info.poster = Self.image(first["poster_path"])
            let details = try await Self.get("/movie/\(id)", ["language": "fr-FR"])
            if let coll = details["belongs_to_collection"] as? [String: Any], let cid = coll["id"] as? Int {
                info.collectionID = cid
                info.collectionName = (coll["name"] as? String).map(Self.cleanCollection)
            }
        }
        cache.set(key, info)
        return info
    }

    nonisolated private func lookup(_ s: SeriesItem) async throws -> TmdbCache.Info {
        let key = Self.seriesKey(s)
        if let known = cache.get(key) { return known }
        let results = try await Self.get("/search/tv", ["query": Duplicates.key(s.name), "language": "fr-FR"])["results"]
            as? [[String: Any]] ?? []
        let info = TmdbCache.Info(poster: Self.image(results.first?["poster_path"]))
        cache.set(key, info)
        return info
    }

    /// Complète une liste de films (sagas + jaquettes manquantes) ; `update` reçoit la liste au fur et à mesure
    func enrichMovies(_ list: [Movie], update: ([Movie]) -> Void) async {
        guard enabled, !list.isEmpty else { return }
        let todo = Array(list.prefix(Self.maxPerList))
        for start in stride(from: 0, to: todo.count, by: 24) {
            if Task.isCancelled { break }
            let chunk = Array(todo[start..<min(start + 24, todo.count)])
            await withTaskGroup(of: (String, TmdbCache.Info)?.self) { group in
                for (i, m) in chunk.enumerated() {
                    if i >= 4, let done = await group.next(), let found = done {   // 4 recherches à la fois
                        cache.setMovie(found.0, found.1)
                    }
                    group.addTask { [self] in
                        guard let info = try? await self.lookup(m) else { return nil }
                        // Image du fournisseur cassée : la jaquette TMDB prendra le relais
                        if let original = m.imageURL, let p = info.poster, let poster = URL(string: p) {
                            self.cache.setFallback(original, poster)
                        }
                        return (m.id, info)
                    }
                }
                for await result in group {
                    if let found = result { cache.setMovie(found.0, found.1) }
                }
            }
            update(list.map { m in
                guard m.imageURL == nil, let p = cache.movie(m.id)?.poster, let url = URL(string: p) else { return m }
                var copy = m
                copy.imageURL = url
                return copy
            })
            version += 1
        }
        cache.save()
    }

    /// Complète les jaquettes manquantes d'une liste de séries
    func enrichSeries(_ list: [SeriesItem], update: ([SeriesItem]) -> Void) async {
        guard enabled else { return }
        let missing = Array(list.prefix(Self.maxPerList))
        guard !missing.isEmpty else { return }
        var posters: [String: URL] = [:]
        await withTaskGroup(of: (String, String?)?.self) { group in
            for (i, s) in missing.enumerated() {
                if i >= 4, let done = await group.next(), let found = done,
                   let p = found.1, let url = URL(string: p) {
                    posters[found.0] = url
                }
                group.addTask { [self] in
                    guard let info = try? await self.lookup(s) else { return nil }
                    if let original = s.imageURL, let p = info.poster, let poster = URL(string: p) {
                        self.cache.setFallback(original, poster)
                        return nil
                    }
                    return (s.id, info.poster)
                }
            }
            for await r in group {
                if let found = r, let p = found.1, let url = URL(string: p) { posters[found.0] = url }
            }
        }
        version += 1
        update(list.map { s in
            guard s.imageURL == nil, let url = posters[s.id] else { return s }
            var copy = s
            copy.imageURL = url
            return copy
        })
        cache.save()
    }

    /// Vérifie la clé saisie dans Réglages
    func check() async -> String {
        do {
            _ = try await Self.get("/configuration", [:])
            return "Clé TMDB valide ✓"
        } catch NetError.http(let code) where code == 401 {
            return "Clé TMDB refusée : vérifie-la sur themoviedb.org"
        } catch {
            return Net.message(for: error)
        }
    }

    func clear() {
        cache.clear()
        version += 1
    }
}

struct TmdbSettingsSection: View {
    @AppStorage("tmdbKey") private var key = ""
    @State private var status: String?

    var body: some View {
        Section {
            TextField("Clé API TMDB (gratuite)", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Vérifier la clé") {
                status = "Vérification…"
                Task { status = key.isEmpty ? "Désactivé" : await TmdbStore.shared.check() }
            }
            Button("Effacer les infos TMDB", role: .destructive) {
                TmdbStore.shared.clear()
                status = "Infos effacées : elles seront cherchées à nouveau"
            }
            if let status { Text(status).font(.footnote) }
        } header: {
            Text("Sagas et jaquettes depuis Internet")
        } footer: {
            Text("Crée un compte gratuit sur themoviedb.org → Paramètres → API, puis colle ta clé ici. L'appli regroupera alors les sagas d'après TMDB et complétera les jaquettes manquantes. Ce produit utilise l'API TMDB mais n'est ni approuvé ni certifié par TMDB.")
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}
