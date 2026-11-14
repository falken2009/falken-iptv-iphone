import SwiftUI
import UIKit

// MARK: - Contrôle parental

@MainActor
final class ParentalStore: ObservableObject {
    /// Code à 4 chiffres (vide = contrôle parental désactivé)
    @Published private(set) var hasPIN: Bool
    /// Déverrouillé jusqu'à ce que l'appli passe en arrière-plan
    @Published private(set) var unlocked = false
    @Published private(set) var lockedNames: Set<String>
    @Published var autoLockAdult: Bool {
        didSet { defaults.set(autoLockAdult, forKey: "parentalAutoAdult") }
    }

    private let defaults = UserDefaults.standard
    private static let adultWords = ["adult", "xxx", "18+", "+18", "porn", "erot"]

    init() {
        hasPIN = !Keychain.get("parentalPIN").isEmpty
        lockedNames = Set(UserDefaults.standard.stringArray(forKey: "parentalLocked") ?? [])
        autoLockAdult = UserDefaults.standard.object(forKey: "parentalAutoAdult") as? Bool ?? false
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// La catégorie est-elle marquée comme verrouillée (manuellement ou automatiquement) ?
    func isProtected(_ category: String) -> Bool {
        guard hasPIN else { return false }
        let key = Self.fold(category)
        if lockedNames.contains(key) { return true }
        if autoLockAdult, Self.adultWords.contains(where: { key.contains($0) }) { return true }
        return false
    }

    /// Faut-il cacher ce contenu maintenant ?
    func isLocked(_ category: String) -> Bool {
        !unlocked && isProtected(category)
    }

    func isManuallyLocked(_ category: String) -> Bool {
        lockedNames.contains(Self.fold(category))
    }

    func toggleLock(_ category: String) {
        let key = Self.fold(category)
        if lockedNames.contains(key) { lockedNames.remove(key) } else { lockedNames.insert(key) }
        defaults.set(Array(lockedNames), forKey: "parentalLocked")
    }

    func check(_ pin: String) -> Bool {
        pin == Keychain.get("parentalPIN")
    }

    func unlock(with pin: String) -> Bool {
        guard check(pin) else { return false }
        unlocked = true
        return true
    }

    func relock() {
        unlocked = false
    }

    func setPIN(_ pin: String) {
        Keychain.set(pin, for: "parentalPIN")
        hasPIN = true
        unlocked = false
    }

    func disable() {
        Keychain.set("", for: "parentalPIN")
        hasPIN = false
        unlocked = false
    }
}

// MARK: - Saisie du code

struct PINPadView: View {
    let title: String
    var subtitle: String? = nil
    /// Renvoie false si le code est refusé (le clavier vibre et s'efface)
    let onComplete: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @State private var shake = false

    var body: some View {
        ZStack {
            KingBackground(dimmed: true)
            HStack(spacing: 50) {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.kingRed)
                    Text(title).font(.title3.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i < digits.count ? Color.kingRed : .clear)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .frame(width: 16, height: 16)
                        }
                    }
                    .offset(x: shake ? -10 : 0)
                    Button("Annuler") { dismiss() }
                        .padding(.top, 6)
                }
                .frame(maxWidth: 260)

                VStack(spacing: 10) {
                    ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]], id: \.self) { row in
                        HStack(spacing: 10) {
                            ForEach(row, id: \.self) { key in
                                keyButton(key)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 62, height: 48)
        } else {
            Button {
                press(key)
            } label: {
                Text(key)
                    .font(.title2.weight(.semibold))
                    .frame(width: 62, height: 48)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(TileButtonStyle())
        }
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 4 else { return }
        digits.append(key)
        if digits.count == 4 {
            if onComplete(digits) {
                dismiss()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) { shake = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    shake = false
                    digits = ""
                }
            }
        }
    }
}

// MARK: - Réglages du contrôle parental

enum ParentalStep: String, Identifiable {
    case create, confirm, change, disable
    var id: String { rawValue }
}

struct ParentalSettingsSection: View {
    @EnvironmentObject var parental: ParentalStore
    @Binding var step: ParentalStep?

    var body: some View {
        Section {
            if parental.hasPIN {
                Label("Activé", systemImage: "lock.fill")
                    .foregroundStyle(Color.kingRed)
                Toggle("Bloquer les catégories adultes", isOn: $parental.autoLockAdult)
                Button("Changer le code") { step = .change }
                Button("Désactiver le contrôle parental", role: .destructive) { step = .disable }
            } else {
                Button("Activer le contrôle parental") { step = .create }
            }
        } header: {
            Text("Contrôle parental")
        } footer: {
            Text("Appui long sur une catégorie (direct, films ou séries) pour la verrouiller. Les catégories verrouillées demandent le code, qui reste valable tant que l'appli est ouverte.")
        }
        .listRowBackground(Color.black.opacity(0.35))
    }
}

/// Écrans de saisie du code, attachés au formulaire des réglages
struct ParentalSheets: ViewModifier {
    @EnvironmentObject var parental: ParentalStore
    @Binding var step: ParentalStep?
    @State private var firstPIN = ""

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $step) { current in
            switch current {
            case .create:
                PINPadView(title: "Choisis un code", subtitle: "4 chiffres") { pin in
                    firstPIN = pin
                    next(.confirm)
                    return true
                }
            case .confirm:
                PINPadView(title: "Confirme le code") { pin in
                    guard pin == firstPIN else { return false }
                    parental.setPIN(pin)
                    return true
                }
            case .change:
                PINPadView(title: "Code actuel") { pin in
                    guard parental.check(pin) else { return false }
                    next(.create)
                    return true
                }
            case .disable:
                PINPadView(title: "Code actuel", subtitle: "pour désactiver le contrôle parental") { pin in
                    guard parental.check(pin) else { return false }
                    parental.disable()
                    return true
                }
            }
        }
    }

    /// Enchaîne sur l'écran suivant une fois le précédent refermé
    private func next(_ value: ParentalStep) {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            step = value
        }
    }
}

/// Petit cadenas affiché à côté d'une catégorie protégée
struct LockBadge: View {
    @EnvironmentObject var parental: ParentalStore
    let category: String

    var body: some View {
        if parental.isProtected(category) {
            Image(systemName: parental.unlocked ? "lock.open.fill" : "lock.fill")
                .font(.caption)
                .foregroundStyle(Color.kingRed)
        }
    }
}

/// Menu d'appui long pour verrouiller une catégorie
struct LockContextMenu: ViewModifier {
    @EnvironmentObject var parental: ParentalStore
    let category: String

    func body(content: Content) -> some View {
        content.contextMenu {
            if parental.hasPIN {
                if parental.isManuallyLocked(category) {
                    Button {
                        if parental.unlocked { parental.toggleLock(category) }
                    } label: {
                        Label(parental.unlocked ? "Déverrouiller la catégorie" : "Déverrouille d'abord avec le code",
                              systemImage: "lock.open")
                    }
                    .disabled(!parental.unlocked)
                } else {
                    Button {
                        parental.toggleLock(category)
                    } label: {
                        Label("Verrouiller la catégorie", systemImage: "lock")
                    }
                }
            } else {
                Text("Active le contrôle parental dans Réglages")
            }
        }
    }
}

extension View {
    func lockContextMenu(_ category: String) -> some View {
        modifier(LockContextMenu(category: category))
    }
}
