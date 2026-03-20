import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    // ── State ──
    @State private var videoId: String = ""
    @State private var tasks: [ScreenshotTask] = []
    @State private var articleURL: URL?
    @State private var outputDir: URL?

    // ── Player control ──
    @State private var seekToSeconds: Double?
    @State private var captureRequest: UUID?
    @State private var isPlayerReady = false
    @State private var currentQuality: String = "?"

    // ── Batch capture ──
    @State private var isCapturing = false
    @State private var currentCaptureIndex: Int = 0
    @State private var statusMessage: String = "Otvori .article.json za poceti"

    var body: some View {
        HSplitView {
            // ── Left: Video Player ──
            VStack(spacing: 0) {
                if !videoId.isEmpty {
                    YouTubePlayerView(
                        videoId: videoId,
                        seekToSeconds: $seekToSeconds,
                        captureRequest: $captureRequest,
                        onCapture: handleCapture,
                        onReady: {
                            isPlayerReady = true
                            statusMessage = "YouTube stranica ucitana — klikni Play na videu, zatim Capture All"
                        }
                    )
                    .frame(minWidth: 640, minHeight: 360)
                } else {
                    ZStack {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("YouTube Player")
                                .font(.title2)
                                .foregroundColor(.gray)
                            Text("Otvori .article.json za ucitavanje videa")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                    .frame(minWidth: 640, minHeight: 360)
                }

                // ── Controls ──
                HStack(spacing: 12) {
                    Button("Otvori Article JSON") {
                        openArticleJSON()
                    }

                    Divider().frame(height: 20)

                    if !tasks.isEmpty {
                        Button(isCapturing ? "Zaustavi" : "Capture All (\(pendingCount))") {
                            if isCapturing {
                                isCapturing = false
                            } else {
                                startBatchCapture()
                            }
                        }
                        .disabled(!isPlayerReady || pendingCount == 0)
                        .keyboardShortcut(.return, modifiers: .command)
                    }

                    Spacer()

                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .frame(minWidth: 700)

            // ── Right: Screenshot Queue ──
            VStack(spacing: 0) {
                HStack {
                    Text("Screenshots")
                        .font(.headline)
                    Spacer()
                    if !tasks.isEmpty {
                        let done = tasks.filter { $0.status == .completed }.count
                        Text("\(done)/\(tasks.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if tasks.isEmpty {
                    VStack {
                        Spacer()
                        Text("Nema screenshot taskova")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                            ScreenshotRow(task: task)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Click to seek
                                    seekToSeconds = task.seconds
                                    statusMessage = "Seek: \(task.timestamp) — \(task.subtitle)"
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 300, idealWidth: 400)
        }
    }

    // MARK: - Computed

    var pendingCount: Int {
        tasks.filter { $0.status == .pending }.count
    }

    // MARK: - Actions

    func openArticleJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.title = "Odaberi .article.json"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        articleURL = url

        guard let result = loadArticle(from: url) else {
            statusMessage = "Greska pri ucitavanju article.json"
            return
        }

        videoId = result.videoId
        tasks = result.tasks
        isPlayerReady = false

        // Set output directory to same location as article
        let videoBase = url.lastPathComponent
            .replacingOccurrences(of: #"\.wav\.canary\.diarized_.*\.article\.json$"#, with: "", options: .regularExpression)
        outputDir = url.deletingLastPathComponent().appendingPathComponent("\(videoBase)_screenshots_4k")

        statusMessage = "Ucitano \(tasks.count) timestampova za \(result.videoId). Cekam player..."
    }

    func startBatchCapture() {
        guard let dir = outputDir else { return }

        // Create output directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Find first pending
        guard let firstPending = tasks.firstIndex(where: { $0.status == .pending }) else { return }

        isCapturing = true
        currentCaptureIndex = firstPending
        captureNext()
    }

    func captureNext() {
        guard isCapturing, currentCaptureIndex < tasks.count else {
            isCapturing = false
            let done = tasks.filter { $0.status == .completed }.count
            statusMessage = "Batch zavrsen! \(done)/\(tasks.count) screenshotova"
            return
        }

        // Skip already done
        if tasks[currentCaptureIndex].status == .completed {
            currentCaptureIndex += 1
            captureNext()
            return
        }

        let task = tasks[currentCaptureIndex]
        tasks[currentCaptureIndex].status = .capturing
        statusMessage = "Capturing \(task.timestamp) — \(task.subtitle.prefix(40))..."

        // Seek first
        seekToSeconds = task.seconds

        // Then capture after seek settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            captureRequest = UUID()
        }
    }

    func handleCapture(_ image: NSImage?) {
        guard currentCaptureIndex < tasks.count else { return }

        if let image = image, let dir = outputDir {
            let task = tasks[currentCaptureIndex]
            let tsClean = task.timestamp.replacingOccurrences(of: ":", with: "-")
            let videoBase = articleURL?.lastPathComponent
                .replacingOccurrences(of: #"\.wav\.canary\.diarized_.*\.article\.json$"#, with: "", options: .regularExpression) ?? "video"
            let filename = "\(videoBase)_\(tsClean).png"
            let fileURL = dir.appendingPathComponent(filename)

            if savePNG(image: image, to: fileURL) {
                tasks[currentCaptureIndex].status = .completed
                tasks[currentCaptureIndex].outputPath = fileURL.path
                let sizeKB = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
                    .map { $0 / 1024 } ?? 0
                statusMessage = "Saved \(task.timestamp) (\(sizeKB) KB) — \(image.size.width)x\(image.size.height)"
            } else {
                tasks[currentCaptureIndex].status = .failed
                statusMessage = "Failed to save \(task.timestamp)"
            }
        } else {
            tasks[currentCaptureIndex].status = .failed
        }

        // Move to next
        currentCaptureIndex += 1
        if isCapturing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                captureNext()
            }
        }
    }
}

// MARK: - Screenshot Row

struct ScreenshotRow: View {
    let task: ScreenshotTask

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.timestamp)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Text("Iter \(task.iterationNumber)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(task.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(task.status == .completed ? 0.6 : 1.0)
    }

    @ViewBuilder
    var statusIcon: some View {
        switch task.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .capturing:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}

// MARK: - PNG Save

func savePNG(image: NSImage, to url: URL) -> Bool {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }
    do {
        try pngData.write(to: url)
        return true
    } catch {
        print("Save error: \(error)")
        return false
    }
}
