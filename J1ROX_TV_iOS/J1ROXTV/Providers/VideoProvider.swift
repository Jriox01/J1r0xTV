import Foundation

enum ProviderAvailability: Equatable, Sendable {
    case available
    case unsupported(reason: String)
}

struct MediaQuery: Sendable {
    var tmdbID: String?
    var title: String
    var year: String?
    var mediaType: String
}

struct PlaybackSource: Identifiable, Sendable {
    let id = UUID()
    let request: PlaybackRequest
    let url: URL
    let providerID: String
    let providerName: String
    var headers: [String: String] = [:]
    var expiresAt: Date? = nil
    var quality: String? = nil
    var subtitles: [SubtitleTrack] = []
    var duration: Double? = nil
    var resumeState: PlaybackSnapshot? = nil
    var translationName: String? { request.translationName }
    var season: String? { request.season }
    var episode: String? { request.episode }
    var candidate: ProviderCandidate { .init(providerID: providerID, sourceID: request.sourceID ?? "") }
}

struct ProviderCandidate: Hashable, Sendable {
    let providerID: String
    let sourceID: String
}

protocol VideoProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var availability: ProviderAvailability { get }
    func canHandle(_ media: MediaItem) -> Bool
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource
    func search(_ query: MediaQuery) async throws -> [MediaItem]
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption])
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue]
    func translations(in content: [String: JSONValue]) -> [TranslationOption]
    func seasons(in translation: TranslationOption) -> [SeasonOption]
    func episodes(in season: SeasonOption) -> [EpisodeOption]
    /// Enumerates logical candidates, never cached temporary playback URLs.
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest]
    /// Must obtain a fresh URL from the provider for every call, including renewal.
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource
}

enum ProviderError: LocalizedError {
    case mediaNotFound, refreshUnsupported, unauthorized, forbidden
    case network(Error)
    case unsupported, unavailable, selectionUnavailable, expired, invalidResponse, invalidContentType, invalidPlaylist
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .mediaNotFound: return "???????? ?? ??????"
        case .refreshUnsupported: return "???????? ?? ???????????? ?????????? ??????"
        case .unauthorized: return "????????? ??????????? ?????????"
        case .forbidden: return "???????? ??????? ? ???????"
        case .network: return "??????? ?????? ?????????"
        case .unsupported: return "Провайдер пока не поддерживается"
        case .unavailable: return "Нет доступного видеоисточника"
        case .selectionUnavailable: return "Выбранная озвучка или серия недоступна у источника"
        case .expired: return "Срок действия видеоисточника истёк"
        case .http(let code): return "Видеоисточник вернул HTTP \(code)"
        case .invalidResponse: return "Некорректный ответ видеоисточника"
        case .invalidContentType: return "Видеоисточник вернул неподдерживаемый Content-Type"
        case .invalidPlaylist: return "Видеоисточник не вернул HLS-плейлист"
        }
    }
}

// Catalog APIs stay intact; playback refresh is an explicit capability.
extension VideoProvider {
    func canHandle(_ media: MediaItem) -> Bool { availability == .available }
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource {
        throw ProviderError.refreshUnsupported
    }
}
