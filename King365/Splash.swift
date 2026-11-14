import SwiftUI
import UIKit
import AudioToolbox

/// Mise en scène d'ouverture : le faucon Falken apparaît, « FALKEN IPTV » s'écrit lettre par lettre,
/// puis le logo plonge vers l'écran avant de laisser place à l'accueil.
struct SplashView: View {
    let onFinish: () -> Void

    private let letters = Array("FALKEN IPTV")
    @State private var visible = 0
    @State private var crown = false
    @State private var glow = false
    @State private var zoom = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 6) {
                // Le faucon Falken
                Image("FalconMark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 170, height: 130)
                    .foregroundStyle(Color.kingRed)
                    .shadow(color: .white.opacity(0.25), radius: 6)
                    .scaleEffect(crown ? 1 : 0.2)
                    .opacity(crown ? 1 : 0)

                HStack(spacing: 1) {
                    ForEach(letters.indices, id: \.self) { i in
                        Text(String(letters[i]))
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(i < 6 ? Color.kingRed : Color.white)
                            .opacity(i < visible ? 1 : 0)
                            .scaleEffect(i < visible ? 1 : 1.9)
                            .blur(radius: i < visible ? 0 : 10)
                    }
                }
                .fixedSize()
            }
            .shadow(color: Color.kingRed.opacity(glow ? 0.9 : 0.3), radius: glow ? 28 : 8)
            .scaleEffect(zoom ? 8 : 1)
            .opacity(zoom ? 0 : 1)
        }
        .task { await play() }
    }

    private func play() async {
        playIntroSound()

        withAnimation(.spring(duration: 0.6, bounce: 0.4)) { crown = true }
        try? await Task.sleep(for: .milliseconds(350))

        let haptic = UIImpactFeedbackGenerator(style: .light)
        for i in 1...letters.count {
            withAnimation(.easeOut(duration: 0.25)) { visible = i }
            if letters[i - 1] != " " { haptic.impactOccurred() }
            try? await Task.sleep(for: .milliseconds(110))
        }

        withAnimation(.easeInOut(duration: 0.5)) { glow = true }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        try? await Task.sleep(for: .milliseconds(800))

        withAnimation(.easeIn(duration: 0.55)) { zoom = true }
        try? await Task.sleep(for: .milliseconds(550))
        onFinish()
    }

    /// Son d'ouverture (respecte le bouton silencieux de l'iPhone)
    private func playIntroSound() {
        guard let url = Bundle.main.url(forResource: "intro", withExtension: "wav") else { return }
        var soundID: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        let id = soundID
        AudioServicesPlaySystemSoundWithCompletion(id) {
            AudioServicesDisposeSystemSoundID(id)
        }
    }
}
