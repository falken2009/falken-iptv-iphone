import Foundation

// MARK: - Doublons : un seul exemplaire par film ou série, celui de la meilleure qualité

enum Duplicates {
    /// Mentions de qualité, de codec ou de langue qui distinguent deux copies du même titre
    private static let tags = [
        "4k", "uhd", "2160p", "2160", "fhd", "1080p", "1080", "hd", "720p", "720", "sd", "480p", "576p",
        "hdr", "hdr10", "dv", "dolby vision", "hevc", "h265", "h 265", "x265", "h264", "x264", "10bit",
        "multi", "vf", "vff", "vfq", "vf2", "vo", "vostfr", "french", "truefrench", "subfrench",
        "bluray", "blu ray", "webrip", "web dl", "webdl", "web", "hdrip", "dvdrip", "remux", "imax",
        "3d", "cam", "ts", "md", "light", "backup"
    ]

    /// « FR - Avatar (2009) [4K HDR] » → « avatar »
    static func key(_ name: String) -> String {
        var s = stripCatalogPrefix(name)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        s = s.replacingOccurrences(of: #"[\(\[]\s*(19|20)\d{2}\s*[\)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s(19|20)\d{2}\s*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        var words = " " + s + " "
        for tag in tags.sorted(by: { $0.count > $1.count }) {
            while let r = words.range(of: " \(tag) ") {
                words.replaceSubrange(r, with: " ")
            }
        }
        let cleaned = words.split(separator: " ").joined(separator: " ")
        return cleaned.isEmpty ? catalogSortKey(name) : cleaned
    }

    /// Plus c'est haut, meilleure est la copie
    static func quality(_ name: String) -> Int {
        let s = " " + name.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression) + " "
        func has(_ words: String...) -> Bool { words.contains { s.contains(" \($0) ") } }

        var score: Int
        if has("4k", "uhd", "2160p", "2160") { score = 40 }
        else if has("fhd", "1080p", "1080") { score = 30 }
        else if has("hd", "720p", "720") { score = 20 }
        else if has("sd", "480p", "576p") { score = 10 }
        else { score = 18 }                                   // sans mention : sans doute en HD
        if has("hdr", "hdr10", "dv") { score += 3 }
        if has("remux", "bluray") { score += 2 }
        if has("hevc", "h265", "x265") { score += 1 }
        if has("cam", "ts", "md") { score -= 15 }             // copies filmées en salle
        if has("vostfr", "vo", "subfrench") { score -= 1 }    // la VF passe avant à qualité égale
        return score
    }

    /// Garde une seule copie de chaque titre, à la place de la première rencontrée.
    /// Deux titres identiques mais d'années différentes (remakes) restent séparés.
    static func keepBest<T>(_ items: [T], name: (T) -> String, year: (T) -> Int? = { _ in nil }) -> [T] {
        var slots: [String: [(year: Int?, index: Int)]] = [:]
        var result: [T] = []
        for item in items {
            let k = key(name(item))
            let y = year(item)
            if let i = slots[k]?.firstIndex(where: { $0.year == nil || y == nil || $0.year == y }) {
                let slot = slots[k]![i]
                if quality(name(item)) > quality(name(result[slot.index])) {
                    result[slot.index] = item
                }
                if slot.year == nil, let y { slots[k]![i].year = y }
            } else {
                slots[k, default: []].append((y, result.count))
                result.append(item)
            }
        }
        return result
    }
}
