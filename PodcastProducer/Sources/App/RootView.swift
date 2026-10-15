import SwiftUI

/// Two halves of the same job: capture the take, then finish it.
struct RootView: View {
    @StateObject private var studioModel = StudioViewModel()
    @State private var selection: Section = .studio

    enum Section: String, CaseIterable, Identifiable {
        case studio
        case post

        var id: String { rawValue }

        var title: String {
            switch self {
            case .studio: return "Studio"
            case .post: return "Post"
            }
        }

        var icon: String {
            switch self {
            case .studio: return "record.circle"
            case .post: return "wand.and.stars"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch selection {
            case .studio:
                StudioView(model: studioModel)
            case .post:
                PostProcessView(sessionFolder: studioModel.sessionFolderURL,
                                libraryURL: studioModel.libraryURL)
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DOMOVINA Studio")
                        .font(.headline)
                    Text("Realtime podcast companion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .tint(Brand.blue)

            // A recording in progress must be obvious from anywhere in the app.
            if studioModel.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("SNIMA")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
