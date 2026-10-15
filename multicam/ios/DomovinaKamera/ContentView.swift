import AVFoundation
import SwiftUI

@main
struct DomovinaKameraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { model.apply(joinURL: $0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.cameraReady {
                PreviewView(session: model.camera.session) { model.previewAttached() }
                    .ignoresSafeArea()
            }
            overlay
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.prepareCamera()
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 10) {
                Circle().fill(model.connected ? .green : .red).frame(width: 10, height: 10)
                Text(model.config.map { "\($0.room) · \($0.name)" } ?? "Nije spojeno — skeniraj QR")
                    .font(.caption.bold())
                if model.scanning {
                    Text("Skeniram QR…").font(.caption).foregroundStyle(.yellow)
                }
                Spacer()
                if let since = model.recordingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(Self.elapsed(context.date.timeIntervalSince(since)), systemImage: "record.circle.fill")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.red)
                    }
                }
                if let upload = model.upload {
                    Text("Upload \(Int(100 * Double(upload.bytesDone) / Double(max(upload.bytesTotal, 1))))%")
                        .font(.caption.monospacedDigit())
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
            .padding(8)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)

            Spacer()

            HStack {
                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .padding(8)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button(action: model.toggleManualRecording) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 66, height: 66)
                        if model.currentTake != nil {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 28, height: 28)
                        } else {
                            Circle().fill(.red).frame(width: 54, height: 54)
                        }
                    }
                }
                .disabled(!model.cameraReady)
            }
        }
        .padding()
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Kamera") {
                    TextField("Ime kamere", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { model.rename(name) }
                    LabeledContent("Uređaj", value: DeviceInfo.modelIdentifier)
                    LabeledContent("ID", value: String(ConfigStore.deviceID.prefix(8)))
                }
                Section("Relay") {
                    LabeledContent("Soba", value: model.config?.room ?? "—")
                    LabeledContent("Adresa", value: model.config?.relay.host ?? "—")
                    LabeledContent("Veza", value: model.connected ? "spojeno" : "nije spojeno")
                    Button("Skeniraj QR za spajanje") {
                        model.scanning = true
                        dismiss()
                    }
                }
                Section {
                    LabeledContent("Verzija", value: DeviceInfo.appVersion)
                }
            }
            .navigationTitle("Postavke")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotovo") {
                        model.rename(name)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { name = model.config?.name ?? ConfigStore.defaultName }
    }
}

/// The preview layer is handed the session once, in `makeUIView`, and only then is
/// the session started (via `onAttached`) — never concurrently with startRunning.
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onAttached: () -> Void

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        if let connection = view.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        DispatchQueue.main.async(execute: onAttached)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}
