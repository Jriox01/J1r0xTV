import Foundation

struct CinemapProvider: VideoProvider {
    let id = "cinemap"
    let name = "Cinemap"

    // Включаем провайдер для hls-debug.
    let availability = ProviderAvailability.available

    private let streamURL: URL

    init() {
        guard let url = URL(
            string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
        ) else {
            fatalError("Invalid Cinemap debug HLS URL")
        }

        self.streamURL = url
    }

    init(streamURL: URL) {
        self.streamURL = streamURL
    }

    func canHandle(_ media: MediaItem) -> Bool {
        true
    }

    func search(_ query: MediaQuery) async throws -> [MediaItem] {
        []
    }

    func sources(
        for item: MediaItem
    ) async throws -> (MediaItem, [SourceOption]) {
        (
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
        [:]
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
        var updated = request

        updated.providerID = id
        updated.sourceID = id

        return [updated]
    }

    func playback(
        for request: PlaybackRequest
    ) async throws -> PlaybackSource {
        PlaybackSource(
            request: request,
            url: streamURL,
            providerID: id,
            providerName: name,
            headers: [:],
            expiresAt: nil
        )
    }
}