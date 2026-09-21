import Foundation

struct CinemapProvider: VideoProvider {

    let id = "cinemap"
    let name = "Cinemap"

    // =========================================================
    // ВПИШИ СЮДА АДРЕС СВОЕГО / РАЗРЕШЁННОГО VIDEO API
    //
    // Например:
    // https://api.mysite.kz/video/
    //
    // Тогда будут использоваться:
    //
    // POST https://api.mysite.kz/video/content
    // POST https://api.mysite.kz/video/playback
    // =========================================================

    private static let apiBaseURLString = ""

    private let client: SourceAPIClient?

    /// Используем уже существующий в J1ROX parser моделей
    /// TranslationOption / SeasonOption / EpisodeOption.
    ///
    /// Здесь Atodo НЕ используется как источник видео.
    /// Мы используем только его синхронные функции преобразования
    /// существующего JSON формата в UI-модели J1ROX.
    private let selectorParser = AtodoProvider()

    var availability: ProviderAvailability {
        client == nil
            ? .unsupported(
                reason: "Не указан адрес Video API."
            )
            : .available
    }

    init() {

        let value = Self.apiBaseURLString
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard
            !value.isEmpty,
            let url = URL(string: value),
            ["http", "https"].contains(
                url.scheme?.lowercased() ?? ""
            ),
            url.host != nil
        else {
            self.client = nil
            return
        }

        self.client = SourceAPIClient(
            baseURL: url
        )
    }

    init(baseURL: URL) {
        self.client = SourceAPIClient(
            baseURL: baseURL
        )
    }

    // MARK: - Catalog

    /// Поиск здесь специально не выполняем.
    /// J1ROX продолжает использовать ТВОЙ каталог.
    func search(
        _ query: MediaQuery
    ) async throws -> [MediaItem] {
        []
    }

    func canHandle(
        _ media: MediaItem
    ) -> Bool {
        client != nil
    }

    // MARK: - Source

    func sources(
        for item: MediaItem
    ) async throws -> (
        MediaItem,
        [SourceOption]
    ) {

        guard client != nil else {
            throw ProviderError.unsupported
        }

        return (
            item,
            [
                .init(
                    id: id,
                    name: name
                )
            ]
        )
    }

    // MARK: - Voices / seasons / episodes

    func content(
        for item: MediaItem,
        sourceID: String
    ) async throws -> [String: JSONValue] {

        guard let client else {
            throw ProviderError.unsupported
        }

        return try await client.content(
            for: item
        )
    }

    func translations(
        in content: [String: JSONValue]
    ) -> [TranslationOption] {

        selectorParser.translations(
            in: content
        )
    }

    func seasons(
        in translation: TranslationOption
    ) -> [SeasonOption] {

        selectorParser.seasons(
            in: translation
        )
    }

    func episodes(
        in season: SeasonOption
    ) -> [EpisodeOption] {

        selectorParser.episodes(
            in: season
        )
    }

    // MARK: - Request

    func requests(
        for request: PlaybackRequest
    ) async throws -> [PlaybackRequest] {

        guard client != nil else {
            throw ProviderError.unsupported
        }

        var next = request

        next.providerID = id
        next.sourceID = id

        return [next]
    }

    // MARK: - Playback

    func playback(
        for request: PlaybackRequest
    ) async throws -> PlaybackSource {

        guard let client else {
            throw ProviderError.unsupported
        }

        let result = try await client.playback(
            for: request
        )

        return PlaybackSource(
            request: request,
            url: result.url,
            providerID: id,
            providerName: name,
            headers: result.headers,
            expiresAt: result.expiresAt
        )
    }

    // MARK: - Refresh

    func downloads(for request: PlaybackRequest) async throws -> [DownloadVariant] {
        guard let client else { throw ProviderError.unsupported }
        return try await client.downloads(for: request)
    }

    func refresh(
        source: PlaybackSource,
        request: PlaybackRequest
    ) async throws -> PlaybackSource {

        // Не используем старый HLS URL.
        // Если он истёк — спрашиваем API заново.
        try await playback(
            for: request
        )
    }
}
