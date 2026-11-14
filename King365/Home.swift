import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @EnvironmentObject var parental: ParentalStore
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("theme") private var theme: KingTheme = .red
    @State private var showSplash = true
    @State private var profileChosen = false

    var body: some View {
        ZStack {
            Group {
                if store.channels.isEmpty {
                    LoginView()
                } else if profiles.profiles.count > 1 && !profileChosen {
                    ProfilePickerView { profileChosen = true }
                } else {
                    HomeView()
                }
            }
            // Change de thème : toute l'interface est redessinée
            .id(theme)

            if showSplash {
                SplashView { showSplash = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .tint(.kingRed)
        .task { await epg.refreshIfNeeded(store: store) }
        .onChange(of: scenePhase) {
            // Le contrôle parental se reverrouille dès que l'appli passe en arrière-plan
            if scenePhase == .background { parental.relock() }
        }
    }
}

// MARK: - Accueil

enum HomeSection: String, Identifiable {
    case live, guide, vod, series, favorites, settings, voice, radio, account, replay, multi, watchlist
    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore
    @EnvironmentObject var parental: ParentalStore
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var reminders: ReminderStore
    @State private var section: HomeSection?
    @State private var account: AccountInfo?
    @State private var continueItems: [WatchProgress.Started] = []
    @State private var playing: PlayItem?
    @State private var showProfiles = false

    var body: some View {
        GeometryReader { geo in
            // Taille des grandes tuiles calculée pour tenir sur l'écran en paysage
            let hasContinue = !continueItems.isEmpty
            let big = min((geo.size.width - 48 - 3 * 18) / 4, geo.size.height * (hasContinue ? 0.28 : 0.40), 230)
            let small = max(big * 0.42, 60)

            ZStack {
                KingBackground()

                VStack(spacing: 0) {
                    topBar
                        .frame(height: big * 0.42)

                    Spacer(minLength: 6)

                    HStack(spacing: 18) {
                        bigTile("TV EN DIRECT", size: big, .live) { LiveTVIcon() }
                        bigTile("GUIDE", size: big, .guide) { GuideIcon() }
                        bigTile("FILMS", size: big, .vod) { VODIcon() }
                        bigTile("SÉRIES", size: big, .series) { SeriesIcon() }
                    }

                    HStack(spacing: 14) {
                        smallTile("FAVORIS", icon: "star", size: small, .favorites)
                        if store.xtream != nil {
                            smallTile("MA LISTE", icon: "bookmark", size: small, .watchlist)
                        }
                        smallTile("MULTI", icon: "rectangle.split.2x2", size: small, .multi)
                        if store.xtream != nil {
                            smallTile("REPLAY", icon: "clock.arrow.circlepath", size: small, .replay)
                        }
                        smallTile("RADIO", icon: "radio", size: small, .radio)
                        if store.xtream != nil {
                            smallTile("COMPTE", icon: "person.2", size: small, .account)
                        }
                        smallTile("RÉGLAGES", icon: "gearshape.2", size: small, .settings)
                    }
                    .padding(.top, big * 0.12)

                    if hasContinue {
                        continueRow(height: geo.size.height * 0.2)
                            .padding(.top, 10)
                    }

                    Spacer(minLength: 6)
                    footer
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(item: $section, onDismiss: refreshContinue) { section in
            destination(section)
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(parental)
                .environmentObject(profiles)
                .environmentObject(reminders)
                .tint(.kingRed)
        }
        .fullScreenCover(isPresented: $showProfiles, onDismiss: refreshContinue) {
            ProfilePickerView { showProfiles = false }
                .environmentObject(profiles)
                .environmentObject(store)
        }
        .onAppear(perform: refreshContinue)
        .onChange(of: profiles.currentID) { refreshContinue() }
        .onChange(of: reminders.pending?.id) {
            // Un rappel a été touché : on ouvre la chaîne
            if let item = reminders.pending {
                reminders.pending = nil
                playing = item
            }
        }
        .task(id: store.loadedAt) {
            account = try? await store.xtream?.accountInfo()
        }
    }

    private func refreshContinue() {
        continueItems = WatchProgress.inProgress()
    }

    /// « Continuer à regarder » : films et épisodes commencés
    private func continueRow(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Continuer à regarder")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(continueItems) { item in
                        Button {
                            guard let url = item.entry.url else { return }
                            playing = PlayItem(title: item.entry.title ?? "Reprise", url: url, resumeKey: item.key,
                                               startAt: item.entry.position, image: item.entry.image)
                        } label: {
                            HStack(spacing: 8) {
                                PosterImage(url: item.entry.image)
                                    .frame(height: height - 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.entry.title ?? "")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    ProgressView(value: item.entry.fraction)
                                        .tint(.kingRed)
                                    Text("Reste \(WatchProgress.format(item.entry.duration - item.entry.position))")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .frame(width: 120)
                            }
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(TileButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                WatchProgress.clear(item.key)
                                refreshContinue()
                            } label: {
                                Label("Retirer de la liste", systemImage: "xmark")
                            }
                        }
                    }
                }
                .padding(.horizontal, 26)
            }
            .frame(height: height)
        }
        .fullScreenCover(item: $playing, onDismiss: refreshContinue) { item in
            PlayerView(item: item)
        }
    }

    private var topBar: some View {
        ZStack {
            KingLogo(size: 26)
            HStack(spacing: 22) {
                Button {
                    showProfiles = true
                } label: {
                    ProfileAvatar(profile: profiles.current, size: 32)
                }
                .accessibilityLabel("Changer de profil")
                Spacer()
                if store.xtream != nil {
                    topButton("mic", label: "Recherche vocale", .voice)
                }
                topButton("magnifyingglass", label: "Rechercher", .live)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 8)
    }

    private func topButton(_ icon: String, label: String, _ target: HomeSection) -> some View {
        Button {
            section = target
        } label: {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }

    private func bigTile<Icon: View>(_ title: String, size: CGFloat, _ target: HomeSection,
                                     @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            section = target
        } label: {
            VStack(spacing: size * 0.04) {
                icon()
                    .frame(width: size * 0.62, height: size * 0.55)
                Text(title)
                    .font(.system(size: size * 0.115, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .modifier(RedTileStyle(cornerRadius: size * 0.1, lineWidth: max(3, size * 0.022)))
        }
        .buttonStyle(TileButtonStyle())
    }

    private func smallTile(_ title: String, icon: String, size: CGFloat, _ target: HomeSection) -> some View {
        Button {
            section = target
        } label: {
            VStack(spacing: size * 0.06) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.4, weight: .light))
                Text(title)
                    .font(.system(size: size * 0.13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .modifier(RedTileStyle(cornerRadius: size * 0.12, lineWidth: 2))
        }
        .buttonStyle(TileButtonStyle())
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if let expiry = account?.expiry {
                Text("Expire : \(expiry.formatted(.dateTime.day().month(.wide).year()))")
            } else if account?.status != nil {
                Text("Abonnement sans date d'expiration")
            } else {
                Text("\(store.channels.count) chaînes")
            }
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func destination(_ section: HomeSection) -> some View {
        switch section {
        case .live: ChannelsView()
        case .guide: GuideGridView()
        case .vod: MoviesView()
        case .series: SeriesView()
        case .favorites: FavoritesView()
        case .settings: SettingsView()
        case .voice: VoiceSearchView()
        case .radio: RadioView()
        case .account: AccountView()
        case .replay: CatchUpView()
        case .multi: MultiScreenView()
        case .watchlist: WatchlistView()
        }
    }
}

// MARK: - Connexion

struct LoginView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var epg: EPGStore

    var body: some View {
        ZStack {
            KingBackground()

            ScrollView {
                VStack(spacing: 18) {
                    KingLogo(size: 44)
                        .padding(.top, 30)
                        .padding(.bottom, 8)

                    Picker("Type", selection: $store.sourceType) {
                        ForEach(SourceType.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Group {
                        if store.sourceType == .xtream {
                            field("Serveur (http://exemple.com:8080)", text: $store.server, url: true)
                            field("Nom d'utilisateur", text: $store.username)
                            SecureField("Mot de passe", text: $store.password)
                                .loginFieldStyle()
                        } else {
                            field("Lien de la playlist M3U", text: $store.m3uURL, url: true)
                        }
                    }

                    Button {
                        Task {
                            await store.reload()
                            if store.errorMessage == nil {
                                await epg.reload(store: store, manual: false)
                            }
                        }
                    } label: {
                        ZStack {
                            Text("S'IDENTIFIER")
                                .font(.headline)
                                .tracking(1)
                                .opacity(store.isLoading ? 0 : 1)
                            if store.isLoading {
                                ProgressView().tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(.white)
                        .background(Color.kingRed, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6), lineWidth: 1))
                    }
                    .disabled(store.isLoading)
                    .padding(.top, 6)

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }

                    Text("Falken IPTV est un lecteur : il ne fournit aucune chaîne.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 10)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, url: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(url ? .URL : .default)
            .loginFieldStyle()
    }
}

private extension View {
    func loginFieldStyle() -> some View {
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, .light)
    }
}
