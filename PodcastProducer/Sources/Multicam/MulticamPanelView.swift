import SwiftUI
import CoreImage.CIFilterBuiltins

/// Studio: telefoni-kamere spojeni na relay, uživo. Snimaj/Zaustavi ih vodi
/// sam; ovdje se vidi tko će snimati i koliko mu je baterije i mjesta.
struct MulticamPanelView: View {
    @ObservedObject var director: MulticamDirector
    var isRecording: Bool
    @State private var showJoin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Telefoni", systemImage: "iphone.gen3")
                    .font(.headline)
                connectionBadge
                Spacer()
                Button {
                    showJoin = true
                } label: {
                    Label("Spoji telefon", systemImage: "qrcode")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showJoin, arrowEdge: .bottom) {
                    JoinCodeView(configuration: director.configuration)
                }
            }

            if director.cameras.isEmpty {
                Text(director.connection == .connected
                     ? "Nijedan telefon nije spojen. Snimanje radi i bez njih."
                     : "Bez veze s relayem. Snimanje radi normalno; start ide telefonima čim se veza vrati.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(director.cameras) { camera in
                    cameraRow(camera)
                }
                if isRecording, let take = director.take {
                    Text("Take: \(take.takeId)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var connectionBadge: some View {
        let (color, text): (Color, String) = switch director.connection {
        case .connected: (.green, "\(director.cameras.count)")
        case .connecting: (.yellow, "spajam…")
        case .failed: (.orange, "nema veze")
        case .off: (.secondary, "isključeno")
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help({ if case .failed(let reason) = director.connection { return reason } else { return "" } }())
    }

    private func cameraRow(_ camera: MulticamDirector.Camera) -> some View {
        let status = camera.status
        let state = status?.state ?? "—"
        return HStack(spacing: 8) {
            Image(systemName: camera.platform == "ios" ? "apple.logo" : "iphone")
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(camera.displayName)
                .lineLimit(1)
            Spacer()
            Text(stateText(state, status))
                .font(.caption.monospacedDigit())
                .foregroundStyle(stateColor(state))
            if let battery = status?.battery {
                Text("\(Int((battery * 100).rounded()))%\(status?.charging == true ? "⚡" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(battery < 0.2 && status?.charging != true ? .orange : .secondary)
            }
            if let free = status?.freeBytes {
                Text(String(format: "%.0f GB", free / 1e9))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(free < 5e9 ? .orange : .secondary)
            }
        }
        .font(.callout)
        .help(status?.error ?? [camera.model, camera.platform].compactMap { $0 }.joined(separator: " · "))
    }

    private func stateText(_ state: String, _ status: MulticamDirector.Camera.Status?) -> String {
        switch state {
        case "recording":
            let seconds = Int(status?.recordingSeconds ?? 0)
            return String(format: "● %d:%02d", seconds / 60, seconds % 60)
        case "uploading":
            guard let upload = status?.upload, upload.bytesTotal > 0 else { return "šalje" }
            return "šalje \(Int(100 * upload.bytesDone / upload.bytesTotal))%"
        case "idle": return "spreman"
        case "error": return "greška"
        default: return state
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "recording": return .red
        case "uploading": return .blue
        case "error": return .orange
        default: return .secondary
        }
    }
}

/// QR za spajanje telefona: aplikacija na telefonu ga skenira (ili otvori link)
/// i zapamti relay, sobu i ključ.
struct JoinCodeView: View {
    var configuration: MulticamConfiguration
    @State private var name = ""

    var body: some View {
        VStack(spacing: 10) {
            if let url = configuration.joinURL(name: name), let image = Self.qrImage(url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                TextField("Ime kamere (neobavezno, npr. Kamera 2)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Skeniraj kamerom telefona na kojem je DOMOVINA Kamera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CopyButton(label: "Kopiraj link", value: url)
            } else {
                Text("Relay nije podešen: Postavke → Telefoni.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
