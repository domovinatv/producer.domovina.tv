import SwiftUI

/// Postavke → Telefoni: relay, soba i ključ za telefone-kamere.
struct MulticamSettingsView: View {
    @ObservedObject var director: MulticamDirector
    @State private var draft = MulticamConfigurationStore.load()
    @State private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Telefoni kao dodatne kamere", isOn: $draft.isEnabled)
                .toggleStyle(.switch)

            Text("Snimaj i Zaustavi u Studiju pokreću i zaustavljaju sve spojene telefone. Svaki telefon snima sam, a snimku šalje nakon stopa; Post je preuzme u mapu sesije. Relay nikad ne blokira snimanje.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Relay").gridColumnAlignment(.trailing)
                    TextField("https://…workers.dev", text: $draft.relayURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Soba").gridColumnAlignment(.trailing)
                    TextField("studio", text: $draft.room)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Ključ").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        SecureField(keyPlaceholder, text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                        Text("Isti ključ kao MULTICAM_KEY u Workeru. Sprema se u macOS Keychain.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Spremi i spoji") {
                    if !keyInput.isEmpty {
                        MulticamConfigurationStore.saveKey(keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyInput = ""
                    }
                    director.update(draft)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(director.connection == .connected ? .green : .secondary)
                .textSelection(.enabled)
        }
    }

    private var keyPlaceholder: String {
        if MulticamConfigurationStore.loadKey() != nil { return "•••••••• (spremljen u Keychain)" }
        if draft.key != nil { return "iz ~/.config/domovina-multicam/key" }
        return ""
    }

    private var statusText: String {
        switch director.connection {
        case .off: return draft.key == nil && draft.isEnabled ? "Nedostaje ključ." : "Isključeno."
        case .connecting: return "Spajam se…"
        case .connected: return "✅ Spojeno, telefona: \(director.cameras.count)"
        case .failed(let reason): return "Nema veze: \(reason)"
        }
    }
}
