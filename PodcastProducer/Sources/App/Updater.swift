import SwiftUI
import Sparkle

/// Sparkle: provjera pri pokretanju i svakih sat vremena (Info.plist), plus
/// „Provjeri ažuriranja…" u izborniku. Sparkle sam odbija update koji nije
/// potpisan našim EdDSA ključem (SUPublicEDKey) i istim Developer ID timom.
///
/// Snimanje ima prednost pred svime: dok traje take, provjera se ne radi (nema
/// prozora koji krade fokus usred razgovora), a ako je update već skinut,
/// ponovno pokretanje čeka kraj snimanja.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var pendingRelaunch: (() -> Void)?

    var updater: SPUUpdater { controller.updater }

    /// Build bez feeda (lokalni `swift run`, bundle bez Info.plista) se ne pokreće:
    /// Sparkle bi inače pri svakom startu javio grešku konfiguracije.
    func start() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !feed.isEmpty else { return }
        controller.startUpdater()
    }

    /// Poziva StudioViewModel kad snimanje stane.
    func recordingDidStop() {
        guard let relaunch = pendingRelaunch else { return }
        pendingRelaunch = nil
        relaunch()
    }

    func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        !RecordingGuard.shared.isRecording
    }

    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard RecordingGuard.shared.isRecording else { return false }
        pendingRelaunch = installHandler
        return true
    }
}

/// „Provjeri ažuriranja…" u izborniku aplikacije; ugašena dok Sparkle već radi provjeru.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var model: Model
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.model = Model(updater: updater)
    }

    var body: some View {
        Button("Provjeri ažuriranja…") { updater.checkForUpdates() }
            .disabled(!model.canCheck)
    }

    private final class Model: ObservableObject {
        @Published var canCheck = false
        init(updater: SPUUpdater) {
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        }
    }
}
