import Foundation

struct CinemapProvider: VideoProvider {
    let id = "cinemap"
    let name = "Cinemap"
    let availability = ProviderAvailability.unsupported(
        reason: "Не найден подтверждённый публичный API или разрешённый интерфейс интеграции Cinemap."
    )
    func search(_ query: MediaQuery) async throws -> [MediaItem] { throw ProviderError.unsupported }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) { throw ProviderError.unsupported }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] { throw ProviderError.unsupported }
    func translations(in content: [String: JSONValue]) -> [TranslationOption] { [] }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { [] }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { [] }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] { throw ProviderError.unsupported }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource { throw ProviderError.unsupported }
}
