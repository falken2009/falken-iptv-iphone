import SwiftUI
import Speech
import AVFoundation

// MARK: - Reconnaissance vocale en français

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        stop()
        error = nil
        transcript = ""

        guard await Self.authorize() else {
            error = "Autorise le micro et la reconnaissance vocale dans Réglages → Falken IPTV."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "La reconnaissance vocale en français n'est pas disponible pour le moment."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            Self.installTap(on: engine.inputNode, request: request)
            engine.prepare()
            try engine.start()
            isListening = true

            task = Self.makeTask(recognizer, request) { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
        } catch {
            self.error = "Impossible de démarrer le micro."
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        if isListening {
            isListening = false
            // Retour au mode lecture vidéo
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.playback, mode: .moviePlayback)
        }
    }

    // Ces fonctions tournent hors du fil principal (micro et serveur de reconnaissance)

    nonisolated private static func installTap(on input: AVAudioInputNode,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func makeTask(
        _ recognizer: SFSpeechRecognizer,
        _ request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speechOK = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

// MARK: - Recherche dans tout le catalogue

/// Garde le catalogue complet en mémoire pendant que l'appli est ouverte
@MainActor
enum CatalogCache {
    static var movies: [Movie] = []
    static var series: [SeriesItem] = []
    static var movieCategoryNames: [String: String] = [:]
    static var seriesCategoryNames: [String: String] = [:]
    static var loadedFor: Date?
}

enum VoiceMatcher {
    private static let fillers = [
        "je voudrais regarder", "je voudrais voir", "je veux regarder", "je veux voir",
        "est-ce que tu as", "tu as", "mets moi", "mets-moi", "mets", "lance", "joue",
        "regarder", "cherche", "trouve", "le film", "la serie", "les films", "les series",
        "un film", "une serie", "film", "serie", "s'il te plait", "stp"
    ]

    private static let numbers = [
        "un": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5",
        "six": "6", "sept": "7", "huit": "8", "neuf": "9", "dix": "10"
    ]

    /// Transforme « Mets-moi le film Avatar deux » en « avatar 2 »
    static func clean(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}' -]"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)

        var changed = true
        while changed {
            changed = false
            for filler in fillers where s.hasPrefix(filler + " ") || s == filler {
                s = String(s.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            for suffix in ["s'il te plait", "stp"] where s.hasSuffix(" " + suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return s.split(separator: " ").map { numbers[String($0)] ?? String($0) }.joined(separator: " ")
    }

    static func rank<Item: PosterItem>(_ items: [Item], query: String, limit: Int = 30) -> [Item] {
        let words = query.split(separator: " ").map(String.init).filter { $0.count > 1 || Int($0) != nil }
        guard !words.isEmpty else { return [] }

        let scored: [(score: Int, item: Item)] = items.compactMap { item in
            let key = catalogSortKey(item.name)
            guard words.allSatisfy({ key.contains($0) }) else { return nil }
            var score = 0
            if key == query { score += 300 }
            if key.hasPrefix(query) { score += 150 }
            if key.hasPrefix(words[0]) { score += 50 }
            score -= key.count / 3
            return (score, item)
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.item)
    }
}

// MARK: - Écrans

/// Version plein écran ouverte depuis l'accueil
struct VoiceSearchView: View {
    var body: some View {
        NavigationStack {
            VoiceSearchContent()
                .toolbar { ToolbarItem(placement: .topBarLeading) { HomeButton() } }
        }
    }
}

struct VoiceSearchContent: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var parental: ParentalStore
    @StateObject private var speech = SpeechRecognizer()
    @State private var movies: [Movie] = []
    @State private var series: [SeriesItem] = []
    @State private var loading = false
    @State private var silenceTimer: Task<Void, Never>?
    @State private var pulse = false

    private var query: String { VoiceMatcher.clean(speech.transcript) }
    private var movieResults: [Movie] {
        VoiceMatcher.rank(movies.filter { allowed($0.categoryID, CatalogCache.movieCategoryNames) }, query: query)
    }
    private var seriesResults: [SeriesItem] {
        VoiceMatcher.rank(series.filter { allowed($0.categoryID, CatalogCache.seriesCategoryNames) }, query: query)
    }

    /// Cache les titres des catégories verrouillées par le contrôle parental
    private func allowed(_ categoryID: String?, _ names: [String: String]) -> Bool {
        guard parental.hasPIN, let id = categoryID, let name = names[id] else { return true }
        return !parental.isLocked(name)
    }

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    var body: some View {
        Group {
            if store.xtream == nil {
                XtreamRequiredView(kind: "Films")
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        micButton
                        status

                        if !query.isEmpty && !speech.isListening {
                            if movieResults.isEmpty && seriesResults.isEmpty && !loading {
                                Text("Aucun film ni série trouvé pour « \(query) ».")
                                    .foregroundStyle(.secondary)
                            }
                            resultSection("Films", items: movieResults) { MovieDetailView(movie: $0) }
                            resultSection("Séries", items: seriesResults) { SeriesDetailView(series: $0) }
                        }
                    }
                    .padding()
                }
            }
        }
        .background(KingBackground(dimmed: true))
        .navigationTitle("Recherche vocale")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCatalog()
            await speech.start()
        }
        .onDisappear {
            silenceTimer?.cancel()
            speech.stop()
        }
        .onChange(of: speech.transcript) {
            // Arrête l'écoute après 1,5 s de silence
            silenceTimer?.cancel()
            silenceTimer = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled { speech.stop() }
            }
        }
    }

    private var micButton: some View {
        Button {
            if speech.isListening {
                speech.stop()
            } else {
                Task { await speech.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.kingRed.opacity(0.25))
                    .frame(width: 120, height: 120)
                    .scaleEffect(speech.isListening && pulse ? 1.25 : 1)
                Circle()
                    .fill(Color.kingRed)
                    .frame(width: 90, height: 90)
                Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: speech.isListening)
            }
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel(speech.isListening ? "Arrêter l'écoute" : "Parler")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var status: some View {
        VStack(spacing: 6) {
            if let error = speech.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if speech.isListening {
                Text("Je t'écoute… dis le titre d'un film ou d'une série")
                    .foregroundStyle(.secondary)
            } else if speech.transcript.isEmpty {
                Text("Touche le micro et dis par exemple « Avatar » ou « la série Lupin »")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !speech.transcript.isEmpty {
                Text("« \(speech.transcript) »")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Chargement du catalogue…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSection<Item: PosterItem, Destination: View>(
        _ title: String, items: [Item], @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) (\(items.count))").font(.headline)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink {
                            destination(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterImage(url: item.imageURL)
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadCatalog() async {
        if CatalogCache.loadedFor == store.loadedAt, !CatalogCache.movies.isEmpty || !CatalogCache.series.isEmpty {
            movies = CatalogCache.movies
            series = CatalogCache.series
            return
        }
        guard let api = store.xtream else { return }
        loading = true
        defer { loading = false }
        async let m = try? api.allMovies()
        async let s = try? api.allSeries()
        async let vc = try? api.vodCategories()
        async let sc = try? api.seriesCategories()
        movies = await m ?? []
        series = await s ?? []
        CatalogCache.movieCategoryNames = Dictionary((await vc ?? []).map { ($0.id, $0.name) },
                                                     uniquingKeysWith: { a, _ in a })
        CatalogCache.seriesCategoryNames = Dictionary((await sc ?? []).map { ($0.id, $0.name) },
                                                      uniquingKeysWith: { a, _ in a })
        CatalogCache.movies = movies
        CatalogCache.series = series
        CatalogCache.loadedFor = store.loadedAt
    }
}
