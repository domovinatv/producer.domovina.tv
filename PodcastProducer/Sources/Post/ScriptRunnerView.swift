import SwiftUI
import AppKit

/// Status + live log of one running post-production script.
struct ScriptRunnerStatusView: View {
    @ObservedObject var runner: ScriptRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = runner.launchError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if runner.isRunning || runner.finished {
                HStack(spacing: 10) {
                    if runner.isRunning {
                        ProgressView().controlSize(.small)
                        Text("Radi… (detalji dolje, log ide i u datoteku u izlaznoj mapi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Prekini", role: .destructive) { runner.cancel() }
                    } else if runner.succeeded {
                        Label("Gotovo", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        if let produced = runner.producedFile {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: produced)])
                            } label: {
                                Label("Prikaži u Finderu", systemImage: "magnifyingglass")
                            }
                        }
                    } else {
                        Label("Stalo (izlazni kod \(runner.exitCode ?? -1)) — pogledaj log",
                              systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("kraj")
                    }
                    .frame(height: 200)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: runner.logText) {
                        proxy.scrollTo("kraj", anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// A copy-to-clipboard button with its own transient confirmation.
struct CopyButton: View {
    var label: String
    var value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Kopirano!" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.green : Color.secondary)
    }
}
