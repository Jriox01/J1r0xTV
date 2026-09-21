import Foundation

// MARK: - Public result

struct SourcePlaybackResult: Sendable {
    let url: URL
    let headers: [String: String]
    let expiresAt: Date?
}

// MARK: - API client

struct SourceAPIClient: Sendable {

    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: Content

    /// Получаем озвучки / сезоны / серии для фильма из нашего каталога.
    ///
    /// POST {baseURL}/content
    ///
    /// Request:
    /// {
    ///   "media_id": "123"
    /// }
    ///
    /// Response:
    /// {
    ///   "translations": [...]
    /// }
    func content(
        for item: MediaItem
    ) async throws -> [String: JSONValue] {

        let response: ContentResponse = try await post(
            path: "content",
            body: [
                "media_id": item.id
            ]
        )

        let translations: [JSONValue] = response.translations.map {
            translationJSON($0)
        }

        return [
            "translations": .array(translations)
        ]
    }

    // MARK: Playback

    /// Получаем HLS уже для конкретной выбранной озвучки/серии.
    ///
    /// POST {baseURL}/playback
    func playback(
        for request: PlaybackRequest
    ) async throws -> SourcePlaybackResult {

        var body: [String: String] = [
            "media_id": request.media.id
        ]

        if let translationID = request.translationID,
           !translationID.isEmpty {
            body["translation_id"] = translationID
        }

        if let season = request.season,
           !season.isEmpty {
            body["season"] = season
        }

        if let episode = request.episode,
           !episode.isEmpty {
            body["episode"] = episode
        }

        let response: PlaybackResponse = try await post(
            path: "playback",
            body: body
        )

        guard
            let value =
                response.file ??
                response.streamURL ??
                response.stream ??
                response.url,
            let url = URL(string: value),
            ["http", "https"].contains(
                url.scheme?.lowercased() ?? ""
            ),
            url.host != nil
        else {
            throw ProviderError.invalidResponse
        }

        let expiration: Date?

        if let timestamp = response.expiresAt {
            expiration = Date(
                timeIntervalSince1970: timestamp
            )
        } else {
            expiration = nil
        }

        return SourcePlaybackResult(
            url: url,
            headers: response.headers ?? [:],
            expiresAt: expiration
        )
    }

    // MARK: HTTP

    /// The existing playback endpoint may additionally advertise permitted direct downloads.
    /// Missing permission/DRM fields intentionally disable downloads without affecting streaming.
    func downloads(for request: PlaybackRequest) async throws -> [DownloadVariant] {
        var body = ["media_id": request.media.id]
        body["translation_id"] = request.translationID
        body["season"] = request.season
        body["episode"] = request.episode
        let response: JSONValue = try await post(path: "playback", body: body)
        return DownloadVariant.parse(response.object ?? [:])
    }

    private func post<T: Decodable>(
        path: String,
        body: [String: String]
    ) async throws -> T {

        let url = baseURL.appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "J1ROXTV/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: body,
                options: []
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }

            switch http.statusCode {
            case 200..<300:
                break

            case 401, 403:
                throw ProviderError.forbidden

            default:
                throw ProviderError.http(
                    http.statusCode
                )
            }

            let decoder = JSONDecoder()

            decoder.keyDecodingStrategy = .convertFromSnakeCase

            do {
                return try decoder.decode(
                    T.self,
                    from: data
                )
            } catch {
                #if DEBUG
                print(
                    "[SourceAPI] JSON decode error:",
                    error
                )

                if let text = String(
                    data: data,
                    encoding: .utf8
                ) {
                    print(
                        "[SourceAPI] Response:",
                        text.prefix(1000)
                    )
                }
                #endif

                throw ProviderError.invalidResponse
            }

        } catch let error as ProviderError {
            throw error

        } catch let error as URLError {
            throw ProviderError.network(error)

        } catch {
            throw ProviderError.invalidResponse
        }
    }

    // MARK: Convert DTO -> existing J1ROX JSON format

    private func translationJSON(
        _ translation: TranslationDTO
    ) -> JSONValue {

        var object: [String: JSONValue] = [
            "id": .string(translation.id),
            "name": .string(translation.name),

            // Сохраняем ID для deferred playback.
            "data": .object([
                "translation_id": .string(
                    translation.id
                )
            ])
        ]

        if let directURL = translation.url,
           !directURL.isEmpty {
            object["url"] = .string(directURL)
        }

        if let seasons = translation.seasons,
           !seasons.isEmpty {

            object["seasons"] = .array(
                seasons.map {
                    seasonJSON(
                        $0,
                        translationID: translation.id
                    )
                }
            )
        }

        return .object(object)
    }

    private func seasonJSON(
        _ season: SeasonDTO,
        translationID: String
    ) -> JSONValue {

        var object: [String: JSONValue] = [
            "id": .string(season.id),
            "season_number": .string(
                season.seasonNumber ?? season.id
            )
        ]

        if let episodes = season.episodes {
            object["episodes"] = .array(
                episodes.map {
                    episodeJSON(
                        $0,
                        translationID: translationID,
                        seasonID: season.id
                    )
                }
            )
        }

        return .object(object)
    }

    private func episodeJSON(
        _ episode: EpisodeDTO,
        translationID: String,
        seasonID: String
    ) -> JSONValue {

        var object: [String: JSONValue] = [
            "id": .string(episode.id),

            "episode_number": .string(
                episode.episodeNumber ?? episode.id
            ),

            "data": .object([
                "translation_id": .string(
                    translationID
                ),
                "season": .string(
                    seasonID
                ),
                "episode": .string(
                    episode.id
                )
            ])
        ]

        if let title = episode.name,
           !title.isEmpty {
            object["name"] = .string(title)
        }

        if let directURL = episode.url,
           !directURL.isEmpty {
            object["url"] = .string(directURL)
        }

        return .object(object)
    }
}

// MARK: - Content DTOs

private struct ContentResponse: Decodable, Sendable {
    let translations: [TranslationDTO]
}

private struct TranslationDTO: Decodable, Sendable {
    let id: String
    let name: String

    /// Необязательно.
    /// Можно вообще не отдавать URL на этапе content.
    let url: String?

    /// Для сериалов.
    let seasons: [SeasonDTO]?
}

private struct SeasonDTO: Decodable, Sendable {
    let id: String
    let seasonNumber: String?
    let episodes: [EpisodeDTO]?
}

private struct EpisodeDTO: Decodable, Sendable {
    let id: String
    let episodeNumber: String?
    let name: String?
    let url: String?
}

// MARK: - Playback DTO

private struct PlaybackResponse: Decodable, Sendable {

    /// Поддерживаем несколько нормальных названий поля.
    let file: String?
    let url: String?
    let stream: String?
    let streamURL: String?

    let headers: [String: String]?

    /// Unix timestamp, например:
    /// 1790000000
    let expiresAt: Double?
}
