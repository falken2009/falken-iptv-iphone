import SwiftUI

// MARK: - État de la connexion (Réglages)

/// Vérifie en un geste : Internet, le serveur de l'abonnement, son temps de réponse et l'état du compte
@MainActor
final class ConnectionCheck: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var advice: String?
    @Published private(set) var running = false
    @Published private(set) var checkedAt: Date?

    func run(store: PlaylistStore) async {
        running = true
        lines = []
        advice = nil
        defer {
            running = false
            checkedAt = Date()
        }

        // 1. Internet
        let internet = await Self.ping(URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        switch internet {
        case .success(let ms):
            lines.append(Line(icon: "wifi", color: .green, title: "Internet", detail: "Connecté · \(ms) ms"))
        case .failure(let error):
            lines.append(Line(icon: "wifi.slash", color: .red, title: "Internet", detail: Net.message(for: error)))
            advice = "L'iPhone n'a pas accès à Internet : vérifie le Wi-Fi ou les données mobiles."
            return
        }

        // 2. Serveur de l'abonnement
        if let api = store.xtream, store.sourceType == .xtream {
            var ping: Result<Int, Error> = .failure(AppError.invalidURL)
            if let url = api.accountURL { ping = await Self.ping(url) }
            switch ping {
            case .success(let ms):
                lines.append(Line(icon: "server.rack", color: ms > 3000 ? .orange : .green,
                                  title: "Serveur", detail: "Répond en \(ms) ms\(ms > 3000 ? " (lent)" : "")"))
                if let account = try? await api.accountInfo() {
                    checkAccount(account)
                } else {
                    lines.append(Line(icon: "person.crop.circle.badge.questionmark", color: .orange,
                                      title: "Compte", detail: "Réponse illisible"))
                    advice = "Le serveur répond mais ne donne pas l'état du compte : vérifie l'adresse du serveur."
                }
            case .failure(let error):
                lines.append(Line(icon: "server.rack", color: .red, title: "Serveur", detail: Net.message(for: error)))
                advice = "Internet fonctionne mais le serveur de ton abonnement ne répond pas. "
                    + "Il est peut-être en panne ou son adresse a changé : contacte ton fournisseur."
            }
        } else if let url = URL(string: store.m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme != nil {
            switch await Self.ping(url) {
            case .success(let ms):
                lines.append(Line(icon: "server.rack", color: ms > 3000 ? .orange : .green,
                                  title: "Playlist", detail: "Répond en \(ms) ms\(ms > 3000 ? " (lent)" : "")"))
                advice = "Tout fonctionne. Avec un lien M3U, la date d'expiration n'est pas connue : demande-la à ton fournisseur."
            case .failure(let error):
                lines.append(Line(icon: "server.rack", color: .red, title: "Playlist", detail: Net.message(for: error)))
                advice = "Internet fonctionne mais le lien de ta playlist ne répond pas : vérifie-le auprès de ton fournisseur."
            }
        } else {
            lines.append(Line(icon: "questionmark.circle", color: .orange, title: "Abonnement",
                              detail: "Aucun abonnement configuré"))
            advice = "Renseigne ton lien M3U ou tes identifiants Xtream ci-dessus."
        }
    }

    private func checkAccount(_ account: AccountInfo) {
        if account.authRefused {
            lines.append(Line(icon: "person.crop.circle.badge.xmark", color: .red, title: "Compte",
                              detail: "Identifiants refusés"))
            advice = "Le serveur répond mais refuse ton nom d'utilisateur ou ton mot de passe : vérifie-les."
            return
        }

        let status = (account.status ?? "").lowercased()
        let expired = account.expiry.map { $0 < Date() } ?? false
        if expired || status == "expired" {
            lines.append(Line(icon: "calendar.badge.exclamationmark", color: .red, title: "Compte", detail: "Expiré"))
            advice = "Ton abonnement est expiré : renouvelle-le auprès de ton fournisseur."
        } else if status.isEmpty || status == "active" {
            lines.append(Line(icon: "person.crop.circle.badge.checkmark", color: .green, title: "Compte",
                              detail: account.isTrial ? "Actif (essai)" : "Actif"))
        } else {
            lines.append(Line(icon: "person.crop.circle.badge.exclamationmark", color: .orange, title: "Compte",
                              detail: "État : \(account.status ?? "")"))
            advice = "Le serveur indique que ton compte n'est pas actif (« \(account.status ?? "") »)."
        }

        if let expiry = account.expiry {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
            let date = expiry.formatted(date: .long, time: .omitted)
            let color: Color = expired ? .red : (days <= 7 ? .orange : .green)
            let detail = expired ? "Le \(date)" : "Le \(date) (dans \(max(days, 0)) jour\(days > 1 ? "s" : ""))"
            lines.append(Line(icon: "calendar", color: color, title: "Expiration", detail: detail))
        } else {
            lines.append(Line(icon: "infinity", color: .green, title: "Expiration", detail: "Illimité"))
        }

        if let max = Int(account.maxConnections ?? ""), max > 0 {
            let active = Int(account.activeConnections ?? "") ?? 0
            let full = active >= max
            lines.append(Line(icon: "rectangle.on.rectangle", color: full ? .orange : .green, title: "Écrans",
                              detail: "\(active) utilisé\(active > 1 ? "s" : "") sur \(max)"))
            if full, advice == nil {
                advice = "Tous tes écrans sont utilisés : arrête la lecture sur un autre appareil si une chaîne refuse de démarrer."
            }
        }
        if advice == nil { advice = "Tout fonctionne." }
    }

    /// Temps de réponse en millisecondes, sans nouvelle tentative
    nonisolated private static func ping(_ url: URL) async -> Result<Int, Error> {
        var request = Net.request(url, timeout: 15)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                return .failure(NetError.http(http.statusCode))
            }
            return .success(Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return .failure(error)
        }
    }
}

struct ConnectionSettingsSection: View {
    @EnvironmentObject var store: PlaylistStore
    @StateObject private var check = ConnectionCheck()

    var body: some View {
        Section {
            Button {
                Task { await check.run(store: store) }
            } label: {
                HStack {
                    Label("Tester la connexion", systemImage: "stethoscope")
                    Spacer()
                    if check.running { ProgressView() }
                }
            }
            .disabled(check.running)

            ForEach(check.lines) { line in
                HStack(spacing: 12) {
                    Image(systemName: line.icon)
                        .foregroundStyle(line.color)
                        .frame(width: 26)
                    Text(line.title)
                    Spacer()
                    Text(line.detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let advice = check.advice {
                Text(advice).font(.footnote)
            }
        } header: {
            Text("État de la connexion")
        } footer: {
            if let at = check.checkedAt {
                Text("Vérifié à \(at.formatted(date: .omitted, time: .shortened))")
            }
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}
