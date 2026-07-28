import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.windows.first?.zoom(nil)
        }
    }

    /// A take in progress is the one thing worth blocking a quit for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecordingGuard.shared.isRecording else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Snimanje je u tijeku"
        alert.informativeText = "Ako izađeš sada, zadnji segment neće biti dovršen. Zaustavi snimanje pa izađi."
        alert.addButton(withTitle: "Ostani")
        alert.addButton(withTitle: "Izađi svejedno")
        alert.alertStyle = .critical
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

/// Tiny bridge so the AppKit delegate can see SwiftUI state.
final class RecordingGuard {
    static let shared = RecordingGuard()
    var isRecording = false
}

@main
struct PodcastProducerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("DOMOVINA Studio") {
            RootView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}
