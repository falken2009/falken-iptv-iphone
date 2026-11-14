import SwiftUI

// MARK: - Thème de couleurs

enum KingTheme: String, CaseIterable, Identifiable {
    case red, blue, green, gold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .red: return "Rouge"
        case .blue: return "Bleu"
        case .green: return "Vert"
        case .gold: return "Or"
        }
    }

    var main: Color {
        switch self {
        case .red: return Color(red: 0.90, green: 0.04, blue: 0.08)
        case .blue: return Color(red: 0.05, green: 0.42, blue: 0.95)
        case .green: return Color(red: 0.05, green: 0.68, blue: 0.30)
        case .gold: return Color(red: 0.85, green: 0.62, blue: 0.10)
        }
    }

    var dark: Color {
        switch self {
        case .red: return Color(red: 0.42, green: 0.0, blue: 0.02)
        case .blue: return Color(red: 0.02, green: 0.12, blue: 0.40)
        case .green: return Color(red: 0.0, green: 0.26, blue: 0.10)
        case .gold: return Color(red: 0.40, green: 0.27, blue: 0.0)
        }
    }

    static var current: KingTheme {
        KingTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .red
    }
}

// MARK: - Profils (favoris, reprise et liste « À voir » séparés)

struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: Int
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var currentID: String = "default"

    static let palette: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .teal, .yellow]

    private let defaults = UserDefaults.standard

    init() {
        var list = [Profile(id: "default", name: "Moi", color: 0)]
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let saved = try? JSONDecoder().decode([Profile].self, from: data), !saved.isEmpty {
            list = saved
        }
        let savedID = UserDefaults.standard.string(forKey: "currentProfile") ?? "default"
        profiles = list
        currentID = list.contains { $0.id == savedID } ? savedID : list[0].id
    }

    var current: Profile {
        profiles.first { $0.id == currentID } ?? profiles[0]
    }

    func select(_ profile: Profile) {
        currentID = profile.id
        defaults.set(profile.id, forKey: "currentProfile")
    }

    @discardableResult
    func add(name: String) -> Profile {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let profile = Profile(id: UUID().uuidString, name: clean.isEmpty ? "Profil \(profiles.count + 1)" : clean,
                              color: profiles.count % Self.palette.count)
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ profile: Profile, to name: String) {
        guard let i = profiles.firstIndex(of: profile) else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty { profiles[i].name = clean }
        save()
    }

    func delete(_ profile: Profile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if currentID == profile.id { select(profiles[0]) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: "profiles")
        }
    }

    /// Clé de stockage propre au profil actif (le profil d'origine garde les anciennes clés)
    nonisolated static func key(_ base: String) -> String {
        let id = UserDefaults.standard.string(forKey: "currentProfile") ?? "default"
        return id == "default" ? base : "\(base).\(id)"
    }
}

/// Pastille ronde avec l'initiale du profil
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 34

    var body: some View {
        Text(String(profile.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ProfileStore.palette[profile.color % ProfileStore.palette.count], in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

/// « Qui regarde ? »
struct ProfilePickerView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var store: PlaylistStore
    let onDone: () -> Void
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        ZStack {
            KingBackground()
            VStack(spacing: 28) {
                Text("Qui regarde ?")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                HStack(spacing: 28) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            profiles.select(profile)
                            store.reloadProfileData()
                            onDone()
                        } label: {
                            VStack(spacing: 10) {
                                ProfileAvatar(profile: profile, size: 90)
                                Text(profile.name)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(TileButtonStyle())
                    }
                    Button {
                        adding = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 34, weight: .semibold))
                                .frame(width: 90, height: 90)
                                .overlay(Circle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6])))
                            Text("Ajouter").font(.headline)
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(TileButtonStyle())
                }
            }
        }
        .alert("Nouveau profil", isPresented: $adding) {
            TextField("Prénom", text: $newName)
            Button("Ajouter") {
                profiles.add(name: newName)
                newName = ""
            }
            Button("Annuler", role: .cancel) { newName = "" }
        }
    }
}

// MARK: - Réglages : profils, abonnements, thème

struct ProfilesSettingsSection: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var store: PlaylistStore
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(profiles.profiles) { profile in
                Button {
                    profiles.select(profile)
                    store.reloadProfileData()
                } label: {
                    HStack {
                        ProfileAvatar(profile: profile, size: 28)
                        Text(profile.name).foregroundStyle(.white)
                        Spacer()
                        if profile.id == profiles.currentID {
                            Image(systemName: "checkmark").foregroundStyle(Color.kingRed)
                        }
                    }
                }
                .swipeActions {
                    if profiles.profiles.count > 1 {
                        Button(role: .destructive) {
                            profiles.delete(profile)
                            store.reloadProfileData()
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            Button("Ajouter un profil") { adding = true }
        } header: {
            Text("Profils")
        } footer: {
            Text("Chaque profil a ses favoris, sa reprise de lecture et sa liste « À voir plus tard ». Glisse vers la gauche pour supprimer.")
        }
        .listRowBackground(Color.black.opacity(0.35))
        .alert("Nouveau profil", isPresented: $adding) {
            TextField("Prénom", text: $newName)
            Button("Ajouter") {
                profiles.add(name: newName)
                newName = ""
            }
            Button("Annuler", role: .cancel) { newName = "" }
        }
    }
}

struct SubscriptionsSettingsSection: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore

    var body: some View {
        Section {
            if store.subscriptions.isEmpty {
                Text("Ton abonnement s'ajoute ici automatiquement après une connexion réussie.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.subscriptions) { sub in
                Button {
                    Task {
                        await store.switchTo(sub)
                        if store.errorMessage == nil {
                            await epg.reload(store: store, manual: false)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: sub.typeRaw == SourceType.m3u.rawValue ? "list.bullet" : "server.rack")
                        VStack(alignment: .leading) {
                            Text(sub.name).foregroundStyle(.white)
                            Text(sub.typeRaw == SourceType.m3u.rawValue ? "Lien M3U" : "Xtream Codes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.isCurrent(sub) {
                            Image(systemName: "checkmark").foregroundStyle(Color.kingRed)
                        }
                    }
                }
                .disabled(store.isLoading)
                .swipeActions {
                    Button(role: .destructive) {
                        store.deleteSubscription(sub)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Abonnements")
        } footer: {
            Text("Touche un abonnement pour passer dessus. Pour en ajouter un, saisis ses identifiants plus haut puis « Charger la playlist ».")
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}

struct ThemeSettingsSection: View {
    @AppStorage("theme") private var theme: KingTheme = .red

    var body: some View {
        Section("Thème") {
            HStack(spacing: 18) {
                ForEach(KingTheme.allCases) { t in
                    Button {
                        theme = t
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(LinearGradient(colors: [t.main, t.dark], startPoint: .top, endPoint: .bottom))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(.white, lineWidth: theme == t ? 3 : 0))
                            Text(t.label).font(.caption).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}
