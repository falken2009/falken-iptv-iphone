import SwiftUI
import CryptoKit
import CommonCrypto

// MARK: - Synchronisation des abonnements avec la Fire TV

/// Les abonnements sont chiffrés (AES-256-GCM) avec le « mot de passe de synchronisation » avant
/// d'être envoyés à une base Firebase : le serveur ne voit jamais les identifiants.
/// Le format est identique à celui de l'appli Fire TV (Sync.kt) : ne pas le modifier d'un seul côté.
enum SyncService {
    struct Item: Codable {
        var name: String
        var mode: String
        var server: String
        var user: String
        var pass: String
        var m3u: String
    }

    private static let base = "https://falken-iptv-default-rtdb.europe-west1.firebasedatabase.app"
    private static let salt = "falken-iptv-sync"

    static var password: String {
        get { UserDefaults.standard.string(forKey: "syncPassword") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "syncPassword") }
    }

    private static func docId(_ p: String) -> String {
        let hash = SHA256.hash(data: Data(("falken-sync-id|" + p).utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(40))
    }

    private static func key(_ p: String) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pwd = Array(p.utf8)
        let saltBytes = Array(salt.utf8)
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pwd.map { Int8(bitPattern: $0) }, pwd.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 20_000,
            &derived, derived.count
        )
        return SymmetricKey(data: Data(derived))
    }

    private static func url(_ p: String) -> URL {
        URL(string: "\(base)/sync/\(docId(p)).json")!
    }

    /// Abonnements publiés par l'autre appareil (nil si rien n'a encore été publié)
    static func fetch(_ p: String) async throws -> [Item]? {
        let (data, response) = try await URLSession.shared.data(from: url(p))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let b64 = json["d"] as? String, let combined = Data(base64Encoded: b64) else { return nil }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: key(p))
        return try JSONDecoder().decode([Item].self, from: plain)
    }

    static func push(_ p: String, _ items: [Item]) async throws {
        let plain = try JSONEncoder().encode(items)
        let sealed = try AES.GCM.seal(plain, using: key(p))
        guard let combined = sealed.combined else { throw URLError(.cannotParseResponse) }
        let body: [String: Any] = ["d": combined.base64EncodedString(), "t": Int(Date().timeIntervalSince1970 * 1000)]
        var request = URLRequest(url: url(p))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}

struct SyncSettingsSection: View {
    @EnvironmentObject var store: PlaylistStore
    @State private var password = SyncService.password

    var body: some View {
        Section {
            TextField("Mot de passe de synchronisation", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Enregistrer et synchroniser") {
                SyncService.password = password
                Task { await store.syncNow() }
            }
            if !store.syncStatus.isEmpty { Text(store.syncStatus).font(.footnote) }
        } header: {
            Text("Synchronisation Fire TV ↔ iPhone")
        } footer: {
            Text("Choisis un mot de passe long, identique sur la Fire TV et l'iPhone. Tes abonnements sont chiffrés avant l'envoi : personne ne peut les lire.")
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}
