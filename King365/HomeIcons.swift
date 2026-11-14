import SwiftUI

// MARK: - Style des tuiles rouges à bordure blanche

struct RedTileStyle: ViewModifier {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(colors: [Color.kingRed, .kingDarkRed],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.92), lineWidth: lineWidth)
            )
            .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }
}

// MARK: - Icônes des grandes tuiles (dessin au trait blanc)

/// Petite pastille ronde posée sur une icône
private struct Badge: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.kingRed)
            Circle().stroke(.white, lineWidth: max(2, size * 0.07))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
        }
        .frame(width: size, height: size)
    }
}

/// Téléviseur + bouton lecture + pastille Wi-Fi
struct LiveTVIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Image(systemName: "tv")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                Image(systemName: "play")
                    .font(.system(size: s * 0.26, weight: .light))
                    .offset(y: -s * 0.07)
                Badge(symbol: "wifi", size: s * 0.38)
                    .offset(x: g.size.width * 0.36, y: s * 0.2)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Téléviseur + « i » d'information
struct GuideIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Image(systemName: "tv")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                Image(systemName: "info.circle.fill")
                    .font(.system(size: s * 0.34, weight: .regular))
                    .offset(y: -s * 0.07)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Clap de cinéma + lecture
struct VODIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Image(systemName: "movieclapper")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                Image(systemName: "play")
                    .font(.system(size: s * 0.2, weight: .light))
                    .offset(y: s * 0.14)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Écrans empilés + bulle de liste d'épisodes
struct SeriesIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Image(systemName: "play.rectangle.on.rectangle")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .padding(s * 0.06)
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: s * 0.3, weight: .light))
                    .padding(s * 0.03)
                    .background(Color.kingDarkRed, in: RoundedRectangle(cornerRadius: s * 0.05))
                    .offset(x: g.size.width * 0.33, y: -s * 0.3)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - Radio

struct RadioView: View {
    @EnvironmentObject var store: PlaylistStore

    private var stations: [Channel] {
        store.channels.filter { $0.group.localizedCaseInsensitiveContains("radio") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if stations.isEmpty {
                    ContentUnavailableView(
                        "Aucune radio",
                        systemImage: "radio",
                        description: Text("Ton abonnement ne contient pas de catégorie Radio.")
                    )
                    .background(KingBackground(dimmed: true))
                } else {
                    ChannelList(channels: stations)
                }
            }
            .navigationTitle("Radio")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

// MARK: - Compte

struct AccountView: View {
    @EnvironmentObject var store: PlaylistStore
    @State private var account: AccountInfo?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Abonnement") {
                    row("Utilisateur", account?.username ?? store.username)
                    row("Statut", statusText)
                    if let expiry = account?.expiry {
                        row("Expire le", expiry.formatted(date: .long, time: .omitted))
                        row("Jours restants", "\(max(Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0, 0))")
                    } else if account != nil {
                        row("Expire le", "Jamais")
                    }
                    if let created = account?.created {
                        row("Créé le", created.formatted(date: .long, time: .omitted))
                    }
                    if let max = account?.maxConnections {
                        row("Écrans simultanés", "\(account?.activeConnections ?? "0") / \(max)")
                    }
                    if account?.isTrial == true {
                        row("Type", "Essai")
                    }
                }
                .listRowBackground(Color.black.opacity(0.35))

                Section("Contenu") {
                    row("Chaînes", "\(store.channels.count)")
                    row("Serveur", store.xtream?.host ?? "—")
                }
                .listRowBackground(Color.black.opacity(0.35))

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .kingBackground()
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Compte")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
            .task {
                defer { loading = false }
                do {
                    account = try await store.xtream?.accountInfo()
                } catch {
                    self.error = Net.message(for: error)
                }
            }
        }
    }

    private var statusText: String {
        switch account?.status?.lowercased() {
        case "active"?: return "Actif"
        case "expired"?: return "Expiré"
        case "banned"?: return "Suspendu"
        case "disabled"?: return "Désactivé"
        case let other?: return other.capitalized
        case nil: return loading ? "…" : "Inconnu"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
