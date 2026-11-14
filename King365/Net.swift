import Foundation
import AVFoundation

// MARK: - Réseau : nouvelles tentatives, identifiant de l'appli, messages d'erreur clairs

/// Certains fournisseurs IPTV n'acceptent que des applis connues : on peut se présenter sous un autre nom
enum UserAgentChoice: String, CaseIterable, Identifiable {
    case king, smarters, vlc, tivimate, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .king: return "Falken IPTV"
        case .smarters: return "IPTV Smarters"
        case .vlc: return "VLC"
        case .tivimate: return "TiviMate"
        case .custom: return "Personnalisé"
        }
    }

    var value: String? {
        switch self {
        case .king: return "FalkenIPTV/1.0"
        case .smarters: return "IPTVSmartersPro"
        case .vlc: return "VLC/3.0.20 LibVLC/3.0.20"
        case .tivimate: return "TiviMate/4.7.0"
        case .custom: return nil
        }
    }
}

enum NetError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            switch code {
            case 401, 403: return "Accès refusé par le serveur : identifiants incorrects, abonnement expiré ou trop d'écrans connectés."
            case 404: return "Adresse introuvable sur le serveur : vérifie le lien ou le serveur."
            case 429: return "Le serveur reçoit trop de demandes. Réessaie dans un instant."
            case 500...599: return "Le serveur rencontre un problème (erreur \(code)). Réessaie plus tard."
            default: return "Le serveur a répondu avec l'erreur \(code)."
            }
        }
    }
}

enum Net {
    static var userAgent: String {
        let defaults = UserDefaults.standard
        let choice = UserAgentChoice(rawValue: defaults.string(forKey: "userAgentChoice") ?? "") ?? .king
        if choice == .custom {
            let custom = (defaults.string(forKey: "userAgentCustom") ?? "").trimmingCharacters(in: .whitespaces)
            return custom.isEmpty ? "FalkenIPTV/1.0" : custom
        }
        return choice.value ?? "FalkenIPTV/1.0"
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// Les redirections (y compris http → https) sont suivies automatiquement.
    static func data(from url: URL, timeout: TimeInterval = 60) async throws -> Data {
        try await retrying {
            let (data, response) = try await session.data(for: request(url, timeout: timeout))
            try check(response)
            return data
        }
    }

    static func download(from url: URL, timeout: TimeInterval = 180) async throws -> URL {
        try await retrying {
            let (file, response) = try await session.download(for: request(url, timeout: timeout))
            try check(response)
            return file
        }
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetError.http(http.statusCode)
        }
    }

    private static let retryable: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed
    ]

    /// Jusqu'à 2 nouvelles tentatives quand la connexion est lente ou coupée (4G, box saturée…)
    private static func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as URLError where attempt < 2 && retryable.contains(error.code) {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            } catch NetError.http(let code) where attempt < 2 && (code >= 500 || code == 429) {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    /// Message en français, compréhensible, pour n'importe quelle erreur réseau
    static func message(for error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "Serveur introuvable : vérifie l'adresse du serveur (sans faute de frappe)."
            case .timedOut:
                return "Le serveur ne répond pas. Vérifie ta connexion ou réessaie plus tard."
            case .cannotConnectToHost:
                return "Connexion refusée : vérifie l'adresse et le port du serveur (par exemple :8080)."
            case .notConnectedToInternet:
                return "Pas de connexion Internet."
            case .networkConnectionLost:
                return "La connexion a été coupée. Réessaie."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "Connexion sécurisée impossible : essaie l'adresse du serveur en http:// au lieu de https://."
            case .badURL, .unsupportedURL:
                return "Adresse invalide. Vérifie le lien ou le serveur."
            case .appTransportSecurityRequiresSecureConnection:
                return "L'iPhone bloque les adresses en http : vérifie le réglage « Allow Arbitrary Loads »."
            default:
                return url.localizedDescription
            }
        }
        if error is DecodingError {
            return "Réponse inattendue : ce serveur n'est peut-être pas un serveur Xtream Codes."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Vidéo pour le lecteur d'Apple, avec le même identifiant d'appli
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
    }
}
