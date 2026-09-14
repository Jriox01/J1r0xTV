import Foundation

struct CinemapProvider: VideoProvider {
    let id = "cinemap"
    let name = "Cinemap"
    let availability = ProviderAvailability.available

    private let streams: [String: URL]

    init() {
        self.streams = [
            // Тестовый MediaItem с id = "42".
            // Нужен пока только для regression-тестов.
            "42": URL(
                string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
            )!
        ]
    }

    init(streams: [String: URL]) {
        self.streams = streams
    }

    func canHandle(_ media: MediaItem) -> Bool {
        streams[media.id] != nil
    }

    func search(_ query: MediaQuery) async throws -> [MediaItem] {
        []
    }

    func sources(
        for item: MediaItem
    ) async throws -> (MediaItem, [SourceOption]) {
        guard streams[item.id] != nil else {
            throw ProviderError.unavailable
        }

        return (
            item,
            [
                SourceOption(
                    id: id,
                    name: name
                )
            ]
        )
    }

    func content(
        for item: MediaItem,
        sourceID: String
    ) async throws -> [String: JSONValue] {
        guard streams[item.id] != nil else {
            throw ProviderError.unavailable
        }

        return [:]
    }

    func translations(
        in content: [String: JSONValue]
    ) -> [TranslationOption] {
        []
    }

    func seasons(
        in translation: TranslationOption
    ) -> [SeasonOption] {
        []
    }

    func episodes(
        in season: SeasonOption
    ) -> [EpisodeOption] {
        []
    }

    func requests(
        for request: PlaybackRequest
    ) async throws -> [PlaybackRequest] {
        guard streams[request.media.id] != nil else {
            throw ProviderError.unavailable
        }

        var updated = request
        updated.providerID = id
        updated.sourceID = id

        return [updated]
    }

    func playback(
        for request: PlaybackRequest
    ) async throws -> PlaybackSource {
        guard let url = streams[request.media.id] else {
            throw ProviderError.unavailable
        }

        return PlaybackSource(
            request: request,
            url: url,
            providerID: id,
            providerName: name,
            headers: [:],
            expiresAt: nil
        )
    }
}