import SwiftUI
import AVFoundation

@main
struct King365App: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var epg = EPGStore()
    @StateObject private var parental = ParentalStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var reminders = ReminderStore()

    init() {
        // Permet le son même en mode silencieux, l'AirPlay et l'image dans l'image
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(parental)
                .environmentObject(profiles)
                .environmentObject(reminders)
                .preferredColorScheme(.dark)
                .task { if !SyncService.password.isEmpty { await store.syncNow() } }
                // Abonnement envoyé depuis la Fire TV (QR code scanné avec l'appareil photo)
                .onOpenURL { url in
                    Task { await store.importTransfer(url) }
                }
        }
    }
}
