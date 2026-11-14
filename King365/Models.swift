import Foundation

struct Channel: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let logo: URL?
    let group: String
    let url: URL
    var tvgID: String? = nil

    /// Clé stable utilisée pour les favoris
    var key: String { url.absoluteString }

    /// Identifiant utilisé pour retrouver la chaîne dans le guide des programmes
    var epgKey: String? {
        guard let id = tvgID?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return nil }
        return id
    }
}

/// Ce que le lecteur doit ouvrir (chaîne, film ou épisode)
struct PlayItem: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    /// Clé de reprise (films et épisodes) ; nil pour le direct
    var resumeKey: String? = nil
    /// Position de départ en secondes
    var startAt: Double? = nil
    /// Affiche, pour la rangée « Continuer à regarder »
    var image: URL? = nil
    /// Chaînes voisines (zapping) ou épisodes suivants de la saison
    var siblings: [PlayItem] = []
    var siblingIndex: Int = 0
    /// true pour les épisodes : enchaîne automatiquement sur le suivant
    var autoNext = false
    /// Chaîne en direct : identifiant dans le guide des programmes, et logo
    var epgKey: String? = nil
    var logo: URL? = nil
    /// Programme en replay : boutons pour sauter 2 minutes (passer les pubs)
    var isReplay = false

    /// Formats que le lecteur d'Apple ne lit pas : ils passent directement par VLC
    var needsVLC: Bool {
        let vlcOnly: Set<String> = ["mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg", "divx",
                                    "xvid", "webm", "m2ts", "vob", "ogv", "rmvb", "3gp"]
        let ext = url.pathExtension.lowercased()
        if vlcOnly.contains(ext) { return true }
        // Chaîne sans extension (liens M3U « /utilisateur/motdepasse/123 ») : c'est presque toujours du TS
        if ext.isEmpty && resumeKey == nil && !autoNext { return true }
        // Chaîne que le lecteur d'Apple n'a pas réussi à lire la dernière fois : directement VLC
        return VLCMemory.contains(url)
    }
}

extension PlayItem {
    var isLive: Bool { resumeKey == nil && !autoNext && !isReplay }

    /// Même chaîne dans l'autre format proposé par les serveurs Xtream : HLS (.m3u8) ⇄ TS (.ts).
    /// Beaucoup de chaînes ne marchent que dans l'un des deux.
    var alternateLiveURL: URL? {
        guard isLive, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path
        if path.lowercased().hasSuffix(".m3u8") {
            comps.path = String(path.dropLast(5)) + ".ts"
        } else if path.lowercased().hasSuffix(".ts") {
            comps.path = String(path.dropLast(3)) + ".m3u8"
        } else if let last = path.split(separator: "/").last, !last.isEmpty, last.allSatisfy(\.isNumber) {
            comps.path = path + ".ts"
        } else {
            return nil
        }
        return comps.url
    }

    /// Copie avec un autre lien (le reste est conservé)
    func withURL(_ newURL: URL) -> PlayItem {
        PlayItem(title: title, url: newURL, resumeKey: resumeKey, startAt: startAt, image: image,
                 siblings: siblings, siblingIndex: siblingIndex, autoNext: autoNext, epgKey: epgKey, logo: logo,
                 isReplay: isReplay)
    }

    /// Chaîne qui a déjà eu besoin de l'autre format : on commence directement par celui-là
    var preferredFormat: PlayItem {
        guard isLive, AlternateFormatMemory.contains(url), let alt = alternateLiveURL else { return self }
        return withURL(alt)
    }
}

/// Se souvient des chaînes qui ne marchent que dans l'autre format (.ts ou .m3u8)
enum AlternateFormatMemory {
    private static let key = "alternateFormatStreams"
    private static func id(_ url: URL) -> String { url.host.map { $0 + url.path } ?? url.absoluteString }

    static func contains(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id(url))
    }

    static func remember(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(id(url)) else { return }
        list.append(id(url))
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: key)
    }

    static func forget(_ url: URL) {
        let list = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != id(url) }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// Se souvient des liens que le lecteur d'Apple n'arrive pas à lire, pour ne plus attendre la prochaine fois
enum VLCMemory {
    private static let key = "vlcOnlyStreams3"

    private static func id(_ url: URL) -> String {
        // Sans les identifiants : seul le chemin de la chaîne compte
        url.host.map { $0 + url.path } ?? url.absoluteString
    }

    static func contains(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id(url))
    }

    static func remember(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(id(url)) else { return }
        list.append(id(url))
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: key)
    }
}

enum SourceType: String, CaseIterable, Identifiable {
    case m3u
    case xtream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m3u: return "Lien M3U"
        case .xtream: return "Xtream Codes"
        }
    }
}

enum AppError: LocalizedError {
    case invalidURL
    case http(Int)
    case empty
    case emptyEPG
    case noEPGSource
    case noEPGIDs
    case refused
    case expired(Date?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Adresse invalide. Vérifie le lien ou le serveur."
        case .http(let code): return "Le serveur a répondu avec l'erreur \(code). Vérifie tes identifiants."
        case .empty: return "Aucune chaîne trouvée dans la playlist."
        case .emptyEPG: return "Le guide ne contient aucun programme pour tes chaînes."
        case .noEPGSource: return "Aucune source de guide : colle un lien XMLTV ci-dessus."
        case .noEPGIDs: return "Tes chaînes n'ont pas d'identifiant de guide (tvg-id). Recharge la playlist."
        case .refused: return "Identifiants refusés : vérifie le nom d'utilisateur et le mot de passe."
        case .expired(let date):
            if let date { return "Ton abonnement a expiré le \(date.formatted(date: .long, time: .omitted))." }
            return "Ton abonnement a expiré."
        }
    }
}

/// Abonnement enregistré (le mot de passe est dans le trousseau)
struct Subscription: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var typeRaw: String
    var server: String
    var username: String
    var m3uURL: String
}

/// Film ou série de la liste « À voir plus tard »
struct WatchItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case movie, series }
    let id: String          // « movie-123 » ou « series-45 »
    let kind: Kind
    let itemID: String
    let name: String
    let image: URL?
    let rating: String?
    let ext: String?
    let categoryID: String?
    let year: Int?
}
