import Foundation

/// Mémorise où tu t'es arrêté dans chaque film ou épisode
enum WatchProgress {
    struct Entry: Codable {
        var position: Double   // secondes
        var duration: Double   // secondes
        var updated: Date
        // Pour la rangée « Continuer à regarder »
        var title: String? = nil
        var image: URL? = nil
        var url: URL? = nil
        var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }
    }

    // Propres au profil actif
    private static var storageKey: String { ProfileStore.key("watchProgress") }
    private static var watchedKey: String { ProfileStore.key("watchedItems") }

    private static var all: [String: Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let dict = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
            return dict
        }
        set {
            // Garde les 300 plus récents pour ne pas grossir indéfiniment
            var dict = newValue
            if dict.count > 300 {
                let keep = dict.sorted { $0.value.updated > $1.value.updated }.prefix(300)
                dict = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            if let data = try? JSONEncoder().encode(dict) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }

    private static var watched: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: watchedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(2000)), forKey: watchedKey) }
    }

    /// Position à laquelle reprendre (nil si rien à reprendre)
    static func entry(for key: String) -> Entry? {
        guard let e = all[key], e.position > 30, e.fraction < 0.95 else { return nil }
        return e
    }

    static func isWatched(_ key: String) -> Bool {
        watched.contains(key)
    }

    struct Started: Identifiable {
        let key: String
        let entry: Entry
        var id: String { key }
    }

    /// Films et épisodes commencés, du plus récent au plus ancien
    static func inProgress(limit: Int = 20) -> [Started] {
        all.filter { $0.value.position > 30 && $0.value.fraction < 0.95 && $0.value.url != nil }
            .sorted { $0.value.updated > $1.value.updated }
            .prefix(limit)
            .map { Started(key: $0.key, entry: $0.value) }
    }

    static func save(item: PlayItem, position: Double, duration: Double) {
        guard let key = item.resumeKey else { return }
        save(key: key, position: position, duration: duration, title: item.title, image: item.image, url: item.url)
    }

    static func save(key: String, position: Double, duration: Double,
                     title: String? = nil, image: URL? = nil, url: URL? = nil) {
        guard position.isFinite, duration.isFinite, duration > 60 else { return }
        var dict = all
        if position / duration >= 0.95 {
            // Fini : on oublie la position et on marque comme vu
            dict[key] = nil
            var w = watched
            w.insert(key)
            watched = w
        } else if position > 30 {
            let old = dict[key]
            dict[key] = Entry(position: position, duration: duration, updated: .now,
                              title: title ?? old?.title, image: image ?? old?.image, url: url ?? old?.url)
        }
        all = dict
    }

    static func clear(_ key: String) {
        var dict = all
        dict[key] = nil
        all = dict
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(m) min"
    }
}
