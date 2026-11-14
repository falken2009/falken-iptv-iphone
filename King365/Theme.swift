import SwiftUI

extension Color {
    /// Couleur principale du thème choisi (rouge par défaut)
    static var kingRed: Color { KingTheme.current.main }
    static var kingDarkRed: Color { KingTheme.current.dark }
}

/// Fond noir et rouge avec reflets en diagonale
struct KingBackground: View {
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let side = max(w, h)
            ZStack {
                Color.black
                LinearGradient(
                    colors: [.black, .kingDarkRed, .kingRed.opacity(0.85), .kingDarkRed, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(dimmed ? 0.4 : 1)

                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(dimmed ? 0.035 : 0.09), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: side * 0.16, height: side * 2.2)
                        .rotationEffect(.degrees(35))
                        .offset(x: CGFloat(i) * w * 0.32 - w * 0.4)
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Fond noir et rouge discret pour les listes et formulaires
    func kingBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(KingBackground(dimmed: true))
    }
}

/// Bouton de retour à l'accueil, placé en haut à gauche de chaque écran
struct HomeButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "house.fill")
        }
        .accessibilityLabel("Accueil")
    }
}

struct KingLogo: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Image("FalconMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size * 1.5, height: size * 1.15)
                .foregroundStyle(Color.kingRed)
            Text("Falken")
                .foregroundStyle(.white)
            Text("IPTV")
                .foregroundStyle(Color.kingRed)
        }
        .font(.system(size: size, weight: .heavy, design: .rounded))
    }
}

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Image de fond d'un film ou d'une série, assombrie pour garder le texte lisible.
/// Une affiche (format portrait) est floutée ; une vraie image de fond reste nette.
struct BackdropBackground: View {
    let url: URL?
    var blur: CGFloat = 0

    var body: some View {
        ZStack {
            KingBackground(dimmed: true)
            if let url {
                GeometryReader { geo in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .blur(radius: blur)
                                .opacity(0.6)
                                .transition(.opacity)
                        }
                    }
                    .id(url)
                }
                LinearGradient(
                    colors: [.black.opacity(0.9), .black.opacity(0.35), .black.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1), value: url)
    }
}

/// Fond des grilles de films et de séries : les affiches défilent doucement en arrière-plan
struct RotatingBackdrop: View {
    let images: [URL]
    @State private var index = 0

    var body: some View {
        BackdropBackground(url: images.isEmpty ? nil : images[index % images.count], blur: 14)
            .task(id: images.count) {
                index = 0
                guard images.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { index += 1 }
                }
            }
    }
}
