import Foundation

/// Lit une playlist M3U / M3U Plus (#EXTINF avec tvg-id, tvg-logo, group-title…)
enum M3UParser {
    static let defaultGroup = "Sans catégorie"

    struct Result {
        var channels: [Channel] = []
        /// Lien du guide indiqué dans l'en-tête (#EXTM3U url-tvg="…")
        var epgURL: URL?
    }

    static func parse(_ text: String) -> Result {
        var result = Result()
        var pendingName: String?
        var pendingLogo: URL?
        var pendingTvgID: String?
        var pendingGroup = defaultGroup

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") {
                if let tvg = attribute("url-tvg", in: line) ?? attribute("x-tvg-url", in: line),
                   let first = tvg.split(separator: ",").first {
                    result.epgURL = URL(string: first.trimmingCharacters(in: .whitespaces))
                }
            } else if line.hasPrefix("#EXTINF") {
                pendingName = name(from: line)
                pendingLogo = attribute("tvg-logo", in: line).flatMap { URL(string: $0) }
                pendingTvgID = attribute("tvg-id", in: line)
                if let g = attribute("group-title", in: line), !g.isEmpty {
                    pendingGroup = g
                } else {
                    pendingGroup = defaultGroup
                }
            } else if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst(8))
            } else if line.hasPrefix("#") {
                continue
            } else if let url = URL(string: line), let name = pendingName {
                result.channels.append(
                    Channel(name: name, logo: pendingLogo, group: pendingGroup, url: url, tvgID: pendingTvgID)
                )
                pendingName = nil
                pendingLogo = nil
                pendingTvgID = nil
                pendingGroup = defaultGroup
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: key + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Le nom de la chaîne est après la première virgule située hors guillemets
    private static func name(from line: String) -> String {
        var inQuotes = false
        for i in line.indices {
            let c = line[i]
            if c == "\"" {
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                let n = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                return n.isEmpty ? "Sans nom" : n
            }
        }
        return "Sans nom"
    }
}
