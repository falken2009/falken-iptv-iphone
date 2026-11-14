import Foundation

// MARK: - Guide des programmes (format XMLTV)

nonisolated struct Programme: Codable, Hashable, Identifiable, Sendable {
    let channel: String
    let title: String
    let desc: String?
    let start: Date
    let stop: Date

    var id: String { "\(channel)|\(start.timeIntervalSince1970)" }

    func isOn(at date: Date) -> Bool { start <= date && date < stop }

    func progress(at date: Date) -> Double {
        let total = stop.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }
}

/// Lecture en flux du fichier XMLTV : ne garde que tes chaînes et les 36 prochaines heures,
/// pour rester rapide même avec un guide de plusieurs centaines de Mo.
nonisolated final class XMLTVParser: NSObject, XMLParserDelegate {
    private let wanted: Set<String>
    private let from: Date
    private let to: Date

    private var result: [String: [Programme]] = [:]
    private var channel: String?
    private var start: Date?
    private var stop: Date?
    private var title: String?
    private var desc: String?
    private var buffer = ""
    private var collecting = false

    private let withZone: DateFormatter
    private let plain: DateFormatter

    init(wanted: Set<String>, from: Date, to: Date) {
        self.wanted = wanted
        self.from = from
        self.to = to

        withZone = DateFormatter()
        withZone.locale = Locale(identifier: "en_US_POSIX")
        withZone.dateFormat = "yyyyMMddHHmmss Z"

        plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyyMMddHHmmss"
    }

    func parse(_ fileURL: URL) -> [String: [Programme]] {
        guard let parser = XMLParser(contentsOf: fileURL) else { return [:] }
        parser.delegate = self
        parser.parse()
        for key in result.keys {
            result[key]?.sort { $0.start < $1.start }
        }
        return result
    }

    private func date(_ value: String?) -> Date? {
        guard let s = value?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return withZone.date(from: s) ?? plain.date(from: String(s.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            let ch = attributeDict["channel"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if wanted.contains(ch),
               let s = date(attributeDict["start"]),
               let e = date(attributeDict["stop"]),
               e > from, s < to {
                channel = ch
                start = s
                stop = e
                title = nil
                desc = nil
            } else {
                channel = nil
            }
        case "title", "desc":
            if channel != nil {
                buffer = ""
                collecting = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "title":
            if collecting, title == nil { title = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            collecting = false
        case "desc":
            if collecting, desc == nil { desc = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            collecting = false
        case "programme":
            if let ch = channel, let s = start, let e = stop {
                let t = (title?.isEmpty == false) ? title! : "Programme"
                let d = (desc?.isEmpty == false) ? desc : nil
                result[ch, default: []].append(Programme(channel: ch, title: t, desc: d, start: s, stop: e))
            }
            channel = nil
        default:
            break
        }
    }
}

@MainActor
final class EPGStore: ObservableObject {
    @Published private(set) var programmes: [String: [Programme]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdate: Date?
    @Published var errorMessage: String?
    @Published var customURL: String {
        didSet { defaults.set(customURL, forKey: "epgCustomURL") }
    }

    private let defaults = UserDefaults.standard

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epg.json")
    }

    /// Accès au guide depuis le lecteur (barre d'infos de la chaîne)
    static weak var shared: EPGStore?

    func programmes(forKey key: String) -> [Programme] { programmes[key] ?? [] }

    init() {
        customURL = defaults.string(forKey: "epgCustomURL") ?? ""
        lastUpdate = defaults.object(forKey: "epgLastUpdate") as? Date
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [Programme]].self, from: data) {
            programmes = cached
        }
        Self.shared = self
    }

    func current(for channel: Channel, at date: Date = .now) -> Programme? {
        guard let key = channel.epgKey else { return nil }
        return programmes[key]?.first { $0.isOn(at: date) }
    }

    func schedule(for channel: Channel, from date: Date = .now) -> [Programme] {
        guard let key = channel.epgKey else { return [] }
        return programmes[key]?.filter { $0.stop > date } ?? []
    }

    /// Priorité : lien saisi à la main, puis guide Xtream, puis lien indiqué dans la playlist
    private func sourceURL(store: PlaylistStore) -> URL? {
        let custom = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return URL(string: custom) }
        if let api = store.xtream { return api.epgURL }
        return store.playlistEPGURL
    }

    /// Mise à jour automatique au démarrage, au plus toutes les 6 heures
    func refreshIfNeeded(store: PlaylistStore) async {
        if let last = lastUpdate, Date().timeIntervalSince(last) < 6 * 3600, !programmes.isEmpty { return }
        await reload(store: store, manual: false)
    }

    func reload(store: PlaylistStore, manual: Bool = true) async {
        guard !isLoading else { return }
        errorMessage = nil

        guard let url = sourceURL(store: store) else {
            if manual { errorMessage = AppError.noEPGSource.errorDescription }
            return
        }
        let wanted = Set(store.channels.compactMap(\.epgKey))
        guard !wanted.isEmpty else {
            if manual { errorMessage = AppError.noEPGIDs.errorDescription }
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let tempFile = try await Net.download(from: url, timeout: 240)

            let file = FileManager.default.temporaryDirectory.appendingPathComponent("epg.xml")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tempFile, to: file)

            let from = Date().addingTimeInterval(-3 * 3600)
            let to = Date().addingTimeInterval(36 * 3600)
            let parsed = await Task.detached(priority: .userInitiated) {
                XMLTVParser(wanted: wanted, from: from, to: to).parse(file)
            }.value
            try? FileManager.default.removeItem(at: file)

            guard !parsed.isEmpty else { throw AppError.emptyEPG }
            programmes = parsed
            lastUpdate = .now
            defaults.set(lastUpdate, forKey: "epgLastUpdate")
            try? JSONEncoder().encode(parsed).write(to: cacheURL)
        } catch {
            if manual || programmes.isEmpty {
                errorMessage = Net.message(for: error)
            }
        }
    }
}
