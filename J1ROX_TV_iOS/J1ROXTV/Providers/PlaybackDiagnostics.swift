import Foundation

struct SubtitleTrack: Identifiable, Sendable {
    let id: String
    let name: String
    let language: String?
    let url: URL
}

struct PlaybackSnapshot: Sendable, Equatable {
    var position: Double = 0
    var isPlaying = true
    var audioLanguage: String?
    var audioName: String?
    var subtitleLanguage: String?
    var subtitleName: String?
    var subtitlesOff = false
}

enum PlaybackError: LocalizedError {
    case invalidURL, manifestInvalid
    case httpStatus(Int)
    case avFoundation(Error), refreshFailed(Error)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Некорректный адрес видео"
        case .manifestInvalid: return "Источник не вернул HLS"
        case .httpStatus(let status): return "Источник вернул HTTP \(status)"
        case .avFoundation: return "Не удалось воспроизвести видео"
        case .refreshFailed: return "Не удалось обновить источник"
        }
    }
}

/// Never emits signed paths, query parameters, credentials or arbitrary server messages.
enum PlaybackDiagnostics {
    static func url(_ url: URL?) -> String {
        guard let url, let host = url.host else { return "unknown" }
        return "\(url.scheme ?? "https")://\(host)\(url.port.map { ":\($0)" } ?? "")/<redacted>"
    }
    static func error(_ error: Error, depth: Int = 0) -> String {
        guard depth < 5 else { return "underlying depth limit" }
        let ns = error as NSError
        var text = "domain=\(ns.domain) code=\(ns.code)"
        if let p = error as? ProviderError, case .http(let status) = p { text += " HTTP=\(status)" }
        if let p = error as? PlaybackError {
            switch p {
            case .httpStatus(let status): text += " HTTP=\(status)"
            case .avFoundation(let underlying), .refreshFailed(let underlying):
                text += " underlying={\(self.error(underlying, depth: depth + 1))}"
            default: break
            }
        }
        if let failed = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            text += " failedURL=\(url(failed))"
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            text += " underlying={\(self.error(underlying, depth: depth + 1))}"
        }
        return text
    }
    static func log(_ message: String) {
        #if DEBUG
        print("[Playback] \(message)")
        #endif
    }
}

struct PlaybackRetryBudget {
    private(set) var attempts = 0
    let limit: Int
    init(limit: Int = 2) { self.limit = max(0, limit) }
    mutating func consume() -> Bool {
        guard attempts < limit else { return false }
        attempts += 1
        return true
    }
}
