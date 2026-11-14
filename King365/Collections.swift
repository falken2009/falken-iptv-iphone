import SwiftUI

// MARK: - Regroupement des films d'une même saga

struct MovieCollection: Identifiable, Hashable {
    let id: String
    let name: String
    let movies: [Movie]
}

enum MovieEntry: Identifiable {
    case movie(Movie)
    case collection(MovieCollection)

    var id: String {
        switch self {
        case .movie(let m): return "m-" + m.id
        case .collection(let c): return "c-" + c.id
        }
    }
}

enum MovieCollections {
    /// Petits mots qui ne suffisent pas à identifier une saga (« La grande… », « Le seigneur… »)
    private static let stopwords: Set<String> = [
        "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "et", "a", "au", "aux", "en",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre", "leur",
        "the", "an", "of", "and", "in", "on", "to", "my", "his", "her"
    ]

    private struct Base {
        let display: String
        let key: String
        let pair: (display: String, key: String)?
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// « FR - Harry Potter et la Chambre des secrets (2002) » → base « Harry Potter et la Chambre des secrets »,
    /// et paire de tête « Harry Potter » utilisée si plusieurs films la partagent.
    /// « Avatar : La Voie de l'eau » → « Avatar » ; « John Wick 3 » → « John Wick » ; « Rocky II » → « Rocky ».
    private static func base(of name: String) -> Base {
        var s = stripCatalogPrefix(name)

        // Mentions de qualité ou de langue : « Avatar 4K », « Avatar [MULTI] »
        s = s.replacingOccurrences(
            of: #"(?i)[\[\(\|]?\b(4k|uhd|fhd|hd|sd|hdr10|hdr|multi|vostfr|vff|vf|1080p|720p|2160p|hevc|h265|x265|x264)\b[\]\)\|]?"#,
            with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // Année : « (2009) », « [2009] » ou « 2009 » en fin de titre
        s = s.replacingOccurrences(of: #"\s*[\(\[]\s*(19|20)\d{2}\s*[\)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(19|20)\d{2}\s*$"#, with: "", options: .regularExpression)

        // Sous-titre après « : » ou « - »
        if let r = s.range(of: #"\s*(:|\s[-–—]\s)"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }

        // Numéro de suite en fin de titre : « 2 », « II », « Partie 2 », « Chapitre 3 »…
        s = s.replacingOccurrences(
            of: #"(?i)\s+((partie|part|chapitre|chapter|episode|épisode|volume|vol\.?|tome)\s*)?(\d{1,2}|[ivx]{1,4})\s*$"#,
            with: "", options: .regularExpression)

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = name }

        let words = s.split(whereSeparator: { $0 == " " }).map(String.init)
        var pair: (String, String)?
        if words.count > 2 {
            let first = fold(words[0]).filter(\.isLetter)
            let second = fold(words[1]).filter(\.isLetter)
            if first.count > 1, second.count > 1, !stopwords.contains(first), !stopwords.contains(second) {
                let display = words[0] + " " + words[1]
                pair = (display, fold(display))
            }
        }
        return Base(display: s, key: fold(s), pair: pair)
    }

    /// Regroupe les films qui appartiennent à la même saga ; l'ordre de la liste d'origine est conservé.
    static func group(_ list: [Movie]) -> [MovieEntry] {
        // Un même film en plusieurs qualités : on ne garde que la meilleure copie
        let movies = Duplicates.keepBest(list, name: { $0.name }, year: { $0.year })
        let bases = movies.map { base(of: $0.name) }

        var pairCount: [String: Int] = [:]
        for b in bases {
            if let p = b.pair { pairCount[p.key, default: 0] += 1 }
        }

        let heuristic: [(key: String, display: String)] = bases.map { b in
            if let p = b.pair, (pairCount[p.key] ?? 0) >= 2 { return (p.key, p.display) }
            return (b.key, b.display)
        }
        // Saga trouvée sur Internet (TMDB) en priorité ; un film non trouvé rejoint quand même
        // la saga TMDB qui porte son nom (« Deadpool » → « Deadpool »)
        let online = movies.map { TmdbStore.collection(for: $0) }
        var onlineByName: [String: (key: String, name: String)] = [:]
        for o in online.compactMap({ $0 }) { onlineByName[fold(o.name)] = o }
        let firstKeys: [(key: String, display: String)] = heuristic.enumerated().map { i, h in
            if let o = online[i] ?? onlineByName[h.key] { return (o.key, o.name) }
            return h
        }
        // « Deadpool & Wolverine », « Alien vs Predator » : un titre qui commence par le nom d'un autre film
        // (au moins 5 lettres) rejoint sa saga
        var known: [String: String] = [:]
        for k in firstKeys where known[k.key] == nil { known[k.key] = k.display }
        let keys: [(key: String, display: String)] = firstKeys.map { k in
            let parent = known.keys
                .filter { $0 != k.key && $0.filter(\.isLetter).count >= 5 && k.key.hasPrefix($0 + " ") }
                .min { $0.count < $1.count }
            if let parent { return (parent, known[parent] ?? k.display) }
            return k
        }

        var buckets: [String: [Movie]] = [:]
        var displayNames: [String: String] = [:]
        for (movie, k) in zip(movies, keys) {
            buckets[k.key, default: []].append(movie)
            if displayNames[k.key] == nil { displayNames[k.key] = k.display }
        }

        var emitted = Set<String>()
        var entries: [MovieEntry] = []
        for (movie, k) in zip(movies, keys) {
            let members = buckets[k.key] ?? []
            if members.count >= 2 {
                guard !emitted.contains(k.key) else { continue }
                emitted.insert(k.key)
                entries.append(.collection(MovieCollection(
                    id: k.key,
                    name: displayNames[k.key] ?? movie.name,
                    movies: chronological(members)
                )))
            } else {
                entries.append(.movie(movie))
            }
        }
        return entries
    }

    /// Ordre de sortie quand l'année est connue, sinon ordre naturel des titres (« 2 » avant « 10 »)
    private static func chronological(_ movies: [Movie]) -> [Movie] {
        movies.sorted { a, b in
            switch (a.year, b.year) {
            case let (ya?, yb?) where ya != yb:
                return ya < yb
            default:
                return catalogSortKey(a.name).localizedStandardCompare(catalogSortKey(b.name)) == .orderedAscending
            }
        }
    }
}

// MARK: - Affichage

/// Grille qui mélange films seuls et sagas regroupées
struct MovieEntryGrid: View {
    let entries: [MovieEntry]
    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    switch entry {
                    case .movie(let movie):
                        NavigationLink {
                            MovieDetailView(movie: movie)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterImage(url: movie.imageURL)
                                Text(movie.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)

                    case .collection(let collection):
                        NavigationLink {
                            CollectionView(collection: collection)
                        } label: {
                            CollectionCell(collection: collection)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .background(RotatingBackdrop(images: Array(entries.prefix(20).compactMap { entry -> URL? in
            switch entry {
            case .movie(let m): return m.imageURL
            case .collection(let c): return c.movies.first?.imageURL
            }
        })))
    }
}

/// Affiche empilée avec le nombre de films de la saga
struct CollectionCell: View {
    let collection: MovieCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if collection.movies.count > 1 {
                    PosterImage(url: collection.movies[1].imageURL)
                        .opacity(0.55)
                        .rotationEffect(.degrees(5))
                        .offset(x: 6, y: -4)
                }
                PosterImage(url: collection.movies[0].imageURL)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(collection.movies.count) films")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.kingRed, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 1))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
            }
            HStack(spacing: 4) {
                Image(systemName: "square.stack.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.kingRed)
                Text(collection.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

struct CollectionView: View {
    let collection: MovieCollection

    var body: some View {
        PosterGrid(items: collection.movies) { movie in
            MovieDetailView(movie: movie)
        }
        .navigationTitle("\(collection.name) · \(collection.movies.count) films")
        .navigationBarTitleDisplayMode(.inline)
    }
}
