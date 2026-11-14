import Foundation
import SwiftUI

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var channels: [Channel] = [] {
        didSet { rebuildIndex() }
    }
    @Published private(set) var groups: [String] = []
    @Published private(set) var byGroup: [String: [Channel]] = [:]
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var subscriptions: [Subscription] = []
    /// Liste « À voir plus tard » du profil actif
    @Published private(set) var watchlist: [WatchItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var playlistEPGURL: URL?
    /// Change à chaque chargement réussi : les onglets Films et Séries se rechargent alors
    @Published private(set) var loadedAt = Date.distantPast
    @Published var errorMessage: String?

    @Published var sourceType: SourceType {
        didSet { defaults.set(sourceType.rawValue, forKey: "sourceType") }
    }
    @Published var m3uURL: String {
        didSet { defaults.set(m3uURL, forKey: "m3uURL") }
    }
    @Published var server: String {
        didSet { defaults.set(server, forKey: "server") }
    }
    @Published var username: String {
        didSet { defaults.set(username, forKey: "username") }
    }
    @Published var password: String {
        didSet { Keychain.set(password, for: "xtreamPassword") }
    }

    private let defaults = UserDefaults.standard

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("channels.json")
    }

    init() {
        sourceType = SourceType(rawValue: defaults.string(forKey: "sourceType") ?? "") ?? .m3u
        m3uURL = defaults.string(forKey: "m3uURL") ?? ""
        server = defaults.string(forKey: "server") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        password = Keychain.get("xtreamPassword")
        favorites = Set(defaults.stringArray(forKey: ProfileStore.key("favorites")) ?? [])
        watchlist = Self.loadWatchlist()
        if let data = defaults.data(forKey: "subscriptions"),
           let list = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = list
        }
        playlistEPGURL = defaults.string(forKey: "playlistEPGURL").flatMap { URL(string: $0) }

        // Recharge la dernière playlist au démarrage, sans réseau
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Channel].self, from: data) {
            channels = cached
            rebuildIndex()
        }
    }

    /// Accès Xtream (films, séries, guide) quand cette source est choisie
    var xtream: XtreamAPI? {
        guard sourceType == .xtream else { return nil }
        return XtreamAPI(server: server, username: username, password: password)
    }

    // MARK: - Favoris

    var favoriteChannels: [Channel] {
        channels.filter { favorites.contains($0.key) }
    }

    func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains(channel.key)
    }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.key) {
            favorites.remove(channel.key)
        } else {
            favorites.insert(channel.key)
        }
        defaults.set(Array(favorites), forKey: ProfileStore.key("favorites"))
    }

    /// Recharge les données du profil actif (favoris, liste « À voir »)
    func reloadProfileData() {
        favorites = Set(defaults.stringArray(forKey: ProfileStore.key("favorites")) ?? [])
        watchlist = Self.loadWatchlist()
    }

    // MARK: - À voir plus tard

    private static func loadWatchlist() -> [WatchItem] {
        guard let data = UserDefaults.standard.data(forKey: ProfileStore.key("watchlist")),
              let list = try? JSONDecoder().decode([WatchItem].self, from: data) else { return [] }
        return list
    }

    func inWatchlist(_ id: String) -> Bool {
        watchlist.contains { $0.id == id }
    }

    func toggleWatchlist(_ item: WatchItem) {
        if let i = watchlist.firstIndex(where: { $0.id == item.id }) {
            watchlist.remove(at: i)
        } else {
            watchlist.insert(item, at: 0)
        }
        if let data = try? JSONEncoder().encode(watchlist) {
            defaults.set(data, forKey: ProfileStore.key("watchlist"))
        }
    }

    // MARK: - Plusieurs abonnements

    func isCurrent(_ sub: Subscription) -> Bool {
        sub.typeRaw == sourceType.rawValue
            && (sourceType == .m3u ? sub.m3uURL == m3uURL : (sub.server == server && sub.username == username))
    }

    func switchTo(_ sub: Subscription) async {
        sourceType = SourceType(rawValue: sub.typeRaw) ?? .xtream
        server = sub.server
        username = sub.username
        m3uURL = sub.m3uURL
        password = Keychain.get("xtreamPassword.\(sub.id)")
        await reload()
    }

    func deleteSubscription(_ sub: Subscription) {
        subscriptions.removeAll { $0.id == sub.id }
        Keychain.set("", for: "xtreamPassword.\(sub.id)")
        saveSubscriptions()
    }

    /// Mémorise l'abonnement qui vient de se connecter avec succès
    private func rememberCurrentSubscription() {
        if let existing = subscriptions.first(where: { isCurrent($0) }) {
            if sourceType == .xtream { Keychain.set(password, for: "xtreamPassword.\(existing.id)") }
            return
        }
        let host = URL(string: sourceType == .m3u ? m3uURL : (server.hasPrefix("http") ? server : "http://" + server))?.host ?? "Abonnement"
        let sub = Subscription(
            id: UUID().uuidString,
            name: sourceType == .m3u ? "Playlist \(host)" : "\(host) · \(username)",
            typeRaw: sourceType.rawValue,
            server: server,
            username: username,
            m3uURL: m3uURL
        )
        subscriptions.append(sub)
        if sourceType == .xtream { Keychain.set(password, for: "xtreamPassword.\(sub.id)") }
        saveSubscriptions()
        if !SyncService.password.isEmpty { Task { await syncNow() } }
    }

    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: "subscriptions")
        }
    }

    // MARK: - Synchronisation avec la Fire TV

    @Published var syncStatus = ""

    /// Récupère les abonnements de l'autre appareil, les ajoute, puis publie la liste complète
    func syncNow() async {
        let p = SyncService.password
        guard !p.isEmpty else { syncStatus = "Aucun mot de passe de synchronisation"; return }
        syncStatus = "Synchronisation…"
        do {
            var added = 0
            if let remote = try await SyncService.fetch(p) {
                for r in remote {
                    let exists = subscriptions.contains {
                        $0.typeRaw == r.mode && (r.mode == "m3u" ? $0.m3uURL == r.m3u : ($0.server == r.server && $0.username == r.user))
                    }
                    if exists { continue }
                    let sub = Subscription(id: UUID().uuidString, name: r.name, typeRaw: r.mode, server: r.server, username: r.user, m3uURL: r.m3u)
                    subscriptions.append(sub)
                    Keychain.set(r.pass, for: "xtreamPassword.\(sub.id)")
                    added += 1
                }
                if added > 0 { saveSubscriptions() }
            }
            let items = subscriptions.map {
                SyncService.Item(name: $0.name, mode: $0.typeRaw, server: $0.server, user: $0.username,
                                 pass: Keychain.get("xtreamPassword.\($0.id)"), m3u: $0.m3uURL)
            }
            try await SyncService.push(p, items)
            syncStatus = added > 0 ? "Synchronisé ✓ · \(added) abonnement(s) reçu(s)" : "Synchronisé ✓"
        } catch {
            syncStatus = "Échec de la synchronisation"
        }
    }

    // MARK: - Abonnement reçu de la Fire TV (QR code)

    /// Lien « falken://abonnement?d=… » scanné avec l'appareil photo : enregistre l'abonnement et charge la liste
    @discardableResult
    func importTransfer(_ url: URL) async -> Bool {
        guard url.scheme == "falken", url.host == "abonnement",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "d" })?.value else { return false }
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        sourceType = (json["m"] as? String) == "m3u" ? .m3u : .xtream
        server = json["s"] as? String ?? ""
        username = json["u"] as? String ?? ""
        password = json["p"] as? String ?? ""
        m3uURL = json["l"] as? String ?? ""
        await reload()
        return true
    }

    // MARK: - Recherche

    func search(_ text: String) -> [Channel] {
        channels.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    // MARK: - Chargement

    func playlistURL() throws -> URL {
        switch sourceType {
        case .m3u:
            let trimmed = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme != nil else { throw AppError.invalidURL }
            return url
        case .xtream:
            guard let url = xtream?.playlistURL else { throw AppError.invalidURL }
            return url
        }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Avec Xtream, on vérifie d'abord le compte pour donner un message clair
            if let api = xtream {
                let account = try await api.accountInfo()
                if account.authRefused {
                    throw AppError.refused
                }
                if account.status?.lowercased() == "expired" {
                    throw AppError.expired(account.expiry)
                }
            }

            let data = try await Net.data(from: try playlistURL(), timeout: 120)

            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let parsed = M3UParser.parse(text)
            guard !parsed.channels.isEmpty else { throw AppError.empty }

            channels = parsed.channels
            playlistEPGURL = parsed.epgURL
            defaults.set(parsed.epgURL?.absoluteString, forKey: "playlistEPGURL")
            loadedAt = .now
            try? JSONEncoder().encode(parsed.channels).write(to: cacheURL)
            rememberCurrentSubscription()
        } catch {
            errorMessage = Net.message(for: error)
        }
    }

    private func rebuildIndex() {
        var order: [String] = []
        var dict: [String: [Channel]] = [:]
        for c in channels {
            if dict[c.group] == nil { order.append(c.group) }
            dict[c.group, default: []].append(c)
        }
        groups = order
        byGroup = dict
    }
}
