import SwiftUI

// MARK: - Chaînes en direct par catégorie

/// Écran en deux colonnes, adapté au mode paysage : catégories à gauche, chaînes à droite
struct ChannelsView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @EnvironmentObject var parental: ParentalStore
    @State private var search = ""
    @State private var selected: String?
    @State private var askPIN = false

    private var currentGroup: String? { selected ?? store.groups.first }

    private var shown: [Channel] {
        if !search.isEmpty { return store.search(search) }
        return currentGroup.flatMap { store.byGroup[$0] } ?? []
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                List(store.groups, id: \.self) { group in
                    let isOn = search.isEmpty && group == currentGroup
                    Button {
                        selected = group
                        search = ""
                    } label: {
                        HStack {
                            Text(group).lineLimit(1)
                            LockBadge(category: group)
                            Spacer()
                            Text("\(store.byGroup[group]?.count ?? 0)")
                                .foregroundStyle(isOn ? .white : .secondary)
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .lockContextMenu(group)
                    .listRowBackground(isOn ? Color.kingRed.opacity(0.85) : Color.black.opacity(0.35))
                }
                .kingBackground()
                .frame(width: 260)

                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1)
                    .ignoresSafeArea()

                ChannelList(channels: shown)
                    .overlay {
                        if search.isEmpty, let group = currentGroup, parental.isLocked(group) {
                            LockedPlaceholder { askPIN = true }
                        }
                    }
            }
            .fullScreenCover(isPresented: $askPIN) {
                PINPadView(title: "Catégorie verrouillée") { parental.unlock(with: $0) }
            }
            .navigationTitle(search.isEmpty ? (currentGroup ?? "TV en direct") : "Résultats")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Rechercher une chaîne")
            .refreshable {
                await store.reload()
                await epg.reload(store: store, manual: false)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

// MARK: - Guide : toutes les chaînes qui ont un programme en cours

struct GuideView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @State private var search = ""

    private var channels: [Channel] {
        store.channels.filter { channel in
            epg.current(for: channel) != nil
                && (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ChannelList(channels: channels)
                .overlay {
                    if channels.isEmpty && search.isEmpty {
                        ContentUnavailableView(
                            "Guide vide",
                            systemImage: "calendar",
                            description: Text("Mets à jour le guide des programmes dans Réglages.")
                        )
                    }
                }
                .navigationTitle("Guide")
                .searchable(text: $search, prompt: "Rechercher une chaîne")
                .refreshable { await epg.reload(store: store) }
                .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

// MARK: - Favoris

struct FavoritesView: View {
    @EnvironmentObject var store: PlaylistStore

    var body: some View {
        NavigationStack {
            Group {
                if store.favoriteChannels.isEmpty {
                    ContentUnavailableView(
                        "Pas encore de favoris",
                        systemImage: "star",
                        description: Text("Touche l'étoile à côté d'une chaîne pour l'ajouter ici.")
                    )
                    .background(KingBackground(dimmed: true))
                } else {
                    ChannelList(channels: store.favoriteChannels)
                }
            }
            .navigationTitle("Favoris")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

// MARK: - Liste de chaînes avec le programme en cours et le suivant

struct ChannelList: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @EnvironmentObject var parental: ParentalStore
    let channels: [Channel]
    @State private var playing: PlayItem?
    @State private var guideFor: Channel?

    private var visible: [Channel] { channels.filter { !parental.isLocked($0.group) } }

    /// La chaîne choisie, avec ses voisines pour zapper dans le lecteur
    private func playItem(for channel: Channel) -> PlayItem {
        let list = visible
        let siblings = list.map { PlayItem(title: $0.name, url: $0.url, epgKey: $0.epgKey, logo: $0.logo) }
        let index = list.firstIndex { $0.id == channel.id } ?? 0
        return PlayItem(title: channel.name, url: channel.url, siblings: siblings, siblingIndex: index,
                        epgKey: channel.epgKey, logo: channel.logo)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            List(visible) { channel in
                row(channel, now: context.date)
                    .listRowBackground(Color.black.opacity(0.35))
            }
            .kingBackground()
        }
        .fullScreenCover(item: $playing) { item in
            PlayerView(item: item)
        }
        .sheet(item: $guideFor) { channel in
            ChannelGuideView(channel: channel)
                .environmentObject(epg)
                .tint(.kingRed)
        }
    }

    private func row(_ channel: Channel, now: Date) -> some View {
        let current = epg.current(for: channel, at: now)
        let next = current == nil ? nil : epg.schedule(for: channel, from: now).dropFirst().first
        return HStack(spacing: 12) {
            AsyncImage(url: channel.logo) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).lineLimit(1)
                if let current {
                    Text(current.title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    ProgressView(value: current.progress(at: now))
                        .tint(.kingRed)
                        .frame(maxWidth: 160)
                }
                if let next {
                    Text("Ensuite \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if current != nil {
                Button {
                    guideFor = channel
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Button {
                store.toggleFavorite(channel)
            } label: {
                Image(systemName: store.isFavorite(channel) ? "star.fill" : "star")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { playing = playItem(for: channel) }
    }
}

// MARK: - Guide d'une chaîne

struct ChannelGuideView: View {
    @EnvironmentObject var epg: EPGStore
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    var body: some View {
        NavigationStack {
            let items = epg.schedule(for: channel)
            List(items) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(timeLabel(p))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if p.isOn(at: .now) {
                            Text("EN DIRECT")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.kingRed, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(p.title).font(.headline)
                    if let d = p.desc {
                        Text(d)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.black.opacity(0.35))
            }
            .kingBackground()
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Pas de programme", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private func timeLabel(_ p: Programme) -> String {
        let hours = p.start.formatted(date: .omitted, time: .shortened)
            + " – " + p.stop.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(p.start) { return hours }
        return p.start.formatted(.dateTime.weekday(.wide)).capitalized + " " + hours
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @State private var parentalStep: ParentalStep?
    @AppStorage("userAgentChoice") private var userAgentChoice: UserAgentChoice = .king
    @AppStorage("userAgentCustom") private var userAgentCustom = ""
    @AppStorage("sleepMinutes") private var sleepMinutes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Type", selection: $store.sourceType) {
                        ForEach(SourceType.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if store.sourceType == .m3u {
                    Section("Lien de la playlist") {
                        TextField("http://…/playlist.m3u", text: $store.m3uURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("Identifiants Xtream") {
                        TextField("Serveur (ex. http://exemple.com:8080)", text: $store.server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Nom d'utilisateur", text: $store.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Mot de passe", text: $store.password)
                    }
                }

                Section {
                    Button {
                        Task {
                            await store.reload()
                            if store.errorMessage == nil {
                                await epg.reload(store: store, manual: false)
                            }
                        }
                    } label: {
                        HStack {
                            Text("Charger la playlist")
                            Spacer()
                            if store.isLoading { ProgressView() }
                        }
                    }
                    .disabled(store.isLoading)

                    if let error = store.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    if !store.channels.isEmpty {
                        Text("\(store.channels.count) chaînes chargées")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Lien XMLTV (facultatif)", text: $epg.customURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task { await epg.reload(store: store) }
                    } label: {
                        HStack {
                            Text("Mettre à jour le guide")
                            Spacer()
                            if epg.isLoading { ProgressView() }
                        }
                    }
                    .disabled(epg.isLoading)

                    if let error = epg.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    if let last = epg.lastUpdate {
                        Text("Mis à jour \(last.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Guide des programmes")
                } footer: {
                    Text("Avec Xtream, le guide est récupéré automatiquement. Avec un lien M3U, il est lu dans la playlist si elle l'indique ; sinon, colle ici le lien XMLTV de ton fournisseur.")
                }

                Section {
                    Picker("Arrêter la lecture après", selection: $sleepMinutes) {
                        Text("Désactivé").tag(0)
                        Text("30 minutes").tag(30)
                        Text("1 heure").tag(60)
                        Text("1 h 30").tag(90)
                        Text("2 heures").tag(120)
                    }
                } header: {
                    Text("Minuteur de veille")
                } footer: {
                    Text("S'applique à chaque vidéo lancée : la lecture s'arrête toute seule après la durée choisie.")
                }
                .listRowBackground(Color.black.opacity(0.35))

                ConnectionSettingsSection()
                TmdbSettingsSection()
                SyncSettingsSection()
                SubscriptionsSettingsSection()
                ProfilesSettingsSection()
                ThemeSettingsSection()

                Section {
                    Picker("Se présenter comme", selection: $userAgentChoice) {
                        ForEach(UserAgentChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if userAgentChoice == .custom {
                        TextField("Identifiant (User-Agent)", text: $userAgentCustom)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Réseau")
                } footer: {
                    Text("Si ton fournisseur refuse la connexion ou la lecture, choisis « IPTV Smarters » ou « VLC », puis recharge la playlist.")
                }
                .listRowBackground(Color.black.opacity(0.35))

                ParentalSettingsSection(step: $parentalStep)

                Section {
                    Text("Falken IPTV est un lecteur : il ne fournit aucune chaîne. Utilise uniquement des playlists auxquelles tu as légalement accès.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .kingBackground()
            .modifier(ParentalSheets(step: $parentalStep))
            .navigationTitle("Réglages")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

/// Affiché à la place d'une catégorie verrouillée
struct LockedPlaceholder: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.kingRed)
            Text("Catégorie verrouillée").font(.headline)
            Button("Saisir le code", action: unlock)
                .buttonStyle(.borderedProminent)
                .tint(.kingRed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KingBackground(dimmed: true))
    }
}
