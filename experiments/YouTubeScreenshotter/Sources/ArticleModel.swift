import Foundation

// MARK: - Article JSON Model

struct ArticleJSON: Codable {
    let metadata: ArticleMetadata?
    let iterations: [ArticleIteration]
}

struct ArticleMetadata: Codable {
    let source_file: String?
    let generated_at: String?
    let model: String?
}

struct ArticleIteration: Codable {
    let iteration_number: Int
    let start_time: String?
    let end_time: String?
    let theme: String?
    let sections: [ArticleSection]
}

struct ArticleSection: Codable {
    let subtitle: String?
    let screenshot_timestamp: String?
    let screenshot_description: String?
    let content: String?
    let keywords: [String]?
    let entities: [String]?
}

// MARK: - Screenshot Task

struct ScreenshotTask: Identifiable {
    let id = UUID()
    let timestamp: String       // HH:MM:SS
    let seconds: Double
    let subtitle: String
    let description: String
    let iterationNumber: Int
    var status: ScreenshotStatus = .pending
    var outputPath: String?
}

enum ScreenshotStatus {
    case pending
    case capturing
    case completed
    case failed
}

// MARK: - Helpers

func parseTimestamp(_ ts: String) -> Double {
    let parts = ts.split(separator: ":").compactMap { Double($0) }
    switch parts.count {
    case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
    case 2: return parts[0] * 60 + parts[1]
    case 1: return parts[0]
    default: return 0
    }
}

func extractVideoId(from filename: String) -> String? {
    // Match _yt_XXXXXXXXXXX pattern
    let pattern = "_yt_([a-zA-Z0-9_-]{11})"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
          let range = Range(match.range(at: 1), in: filename) else {
        return nil
    }
    return String(filename[range])
}

func loadArticle(from url: URL) -> (article: ArticleJSON, videoId: String, tasks: [ScreenshotTask])? {
    guard let data = try? Data(contentsOf: url),
          let article = try? JSONDecoder().decode(ArticleJSON.self, from: data) else {
        return nil
    }

    let videoId = extractVideoId(from: url.lastPathComponent)
    guard let vid = videoId else { return nil }

    var tasks: [ScreenshotTask] = []
    for iter in article.iterations {
        for section in iter.sections {
            guard let ts = section.screenshot_timestamp else { continue }
            tasks.append(ScreenshotTask(
                timestamp: ts,
                seconds: parseTimestamp(ts),
                subtitle: section.subtitle ?? "",
                description: section.screenshot_description ?? "",
                iterationNumber: iter.iteration_number
            ))
        }
    }

    tasks.sort { $0.seconds < $1.seconds }
    return (article, vid, tasks)
}
