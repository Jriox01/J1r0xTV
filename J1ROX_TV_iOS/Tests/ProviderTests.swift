import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw TestFailure(message: message)
    }
}

private struct TestFailure: Error {
    let message: String
}

private actor FixtureAPI: ProviderAPI {
    let series: Bool

    init(series: Bool) {
        self.series = series
    }

    func get(
        path: String,
        query: [String: String]
    ) async throws -> JSONValue {
        let item: JSONValue = .object([
            "id": .string("42"),
            "media_type": .string(series ? "tv" : "movie"),
            "title": .string("Fixture"),
            "release_date": .string("2024-01-01")
        ])

        if path.hasPrefix("api/details/") {
            return item
        }

        if path == "api/search" || path == "api/list" {
            return .array([item])
        }

        if path == "api/source/list" {
            return .object([
                "balancers": .array([
                    .object([
                        "id": .string("one"),
                        "name": .string("One")
                    ])
                ])
            ])
        }

        if path == "api/source/one",
           let encoded = query["data"] {
            guard
                let data = Data(base64Encoded: encoded),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                let voice = object["voice"]
            else {
                throw ProviderError.invalidResponse
            }

            return .object([
                "url": .string(
                    "https://fixture.invalid/\(voice)/movie.m3u8"
                ),
                "quality": .string("1080p"),
                "expires_at": .number(
                    Date()
                        .addingTimeInterval(60)
                        .timeIntervalSince1970
                )
            ])
        }

        if path == "api/source/one" {
            return .object([
                "translations": .array(
                    ["a", "b"].map { voice in
                        var payload: [String: JSONValue] = [
                            "id": .string(voice),
                            "name": .string("Voice \(voice)")
                        ]

                        if series {
                            payload["seasons"] = .array([
                                .object([
                                    "id": .string("1"),
                                    "season_number": .string("1"),
                                    "episodes": .array(
                                        ["1", "2", "3"].map { episode in
                                            .object([
                                                "id": .string(episode),
                                                "episode_number": .string(episode),
                                                "url": .string(
                                                    "https://fixture.invalid/\(voice)/\(episode).m3u8"
                                                )
                                            ])
                                        }
                                    )
                                ])
                            ])
                        } else if voice == "b" {
                            payload["data"] = .object([
                                "voice": .string(voice)
                            ])
                        } else {
                            payload["url"] = .string(
                                "https://fixture.invalid/\(voice)/movie.m3u8"
                            )
                        }

                        return .object(payload)
                    }
                )
            ])
        }

        throw ProviderError.unavailable
    }
}

private struct FixtureProbe: PlaybackProbing {
    var status = 200
    var headStatus = 200
    var type = "application/vnd.apple.mpegurl"
    var body = "#EXTM3U\n#EXT-X-VERSION:3\n"

    func probe(
        _ request: URLRequest,
        maxBytes: Int
    ) async throws -> PlaybackProbe {
        if request.httpMethod == "HEAD" {
            try require(
                maxBytes == 0,
                "HEAD must not read the body"
            )

            return PlaybackProbe(
                status: headStatus,
                mimeType: type,
                prefix: Data()
            )
        }

        try require(
            maxBytes <= 1024,
            "GET prefix must be bounded"
        )

        try require(
            request.value(
                forHTTPHeaderField: "Range"
            ) == "bytes=0-1023",
            "GET must request a short range"
        )

        return PlaybackProbe(
            status: status,
            mimeType: type,
            prefix: Data(
                body.utf8.prefix(maxBytes)
            )
        )
    }
}

private actor FixtureProvider: VideoProvider {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let availability = ProviderAvailability.available

    enum Mode {
        case good
        case fail
        case expiredFirst
        case slow
        case renewing
    }

    let mode: Mode
    var calls = 0

    init(
        _ id: String,
        mode: Mode = .good
    ) {
        self.id = id
        self.name = id
        self.mode = mode
    }

    func search(
        _ query: MediaQuery
    ) async throws -> [MediaItem] {
        []
    }

    func sources(
        for item: MediaItem
    ) async throws -> (MediaItem, [SourceOption]) {
        (item, [])
    }

    func content(
        for item: MediaItem,
        sourceID: String
    ) async throws -> [String: JSONValue] {
        [:]
    }

    nonisolated func translations(
        in content: [String: JSONValue]
    ) -> [TranslationOption] {
        []
    }

    nonisolated func seasons(
        in translation: TranslationOption
    ) -> [SeasonOption] {
        []
    }

    nonisolated func episodes(
        in season: SeasonOption
    ) -> [EpisodeOption] {
        []
    }

    func requests(
        for request: PlaybackRequest
    ) async throws -> [PlaybackRequest] {
        var next = request
        next.providerID = id
        next.sourceID = "default"

        return [next]
    }

    func playback(
        for request: PlaybackRequest
    ) async throws -> PlaybackSource {
        calls += 1

        if mode == .fail {
            throw ProviderError.unavailable
        }

        if mode == .slow {
            try await Task.sleep(
                nanoseconds: 5_000_000_000
            )
        }

        return PlaybackSource(
            request: request,
            url: URL(
                string: "https://fixture.invalid/\(id)/\(calls).m3u8"
            )!,
            providerID: id,
            providerName: name,
            expiresAt:
                mode == .expiredFirst && calls == 1
                ? Date(timeIntervalSinceNow: -60)
                : Date(timeIntervalSinceNow: 60)
        )
    }
}

@main
struct ProviderTests {
    @MainActor
    static func main() async throws {
        try CinemarFixtureTests.run()
        try await runPlaybackTests()
        try await runDownloadTests()
        try require(APIConfig.baseURL.absoluteString == "https://api.atodo.fun/", "ATODO API base")
        let defaults = ProviderResolver().providers
        try require(defaults.map(\.id) == ["atodo"] && defaults.first?.availability == .available,
                    "ATODO is the default; Cinemap is not required")

        let media = MediaItem.parse([
            "id": .string("42"),
            "title": .string("Fixture"),
            "year": .string("2024")
        ])

        let movie = AtodoProvider(
            client: FixtureAPI(series: false)
        )
        let movieSources = try await movie.sources(for: media)
        try require(movieSources.1.map(\.id) == ["one"], "Movie sources use ATODO source/list")

        let matches = try await movie.search(
            .init(
                tmdbID: "42",
                title: "Fixture",
                year: "2024",
                mediaType: "movie"
            )
        )

        try require(
            matches.first?.id == "42",
            "TMDB lookup"
        )

        let byTitle = try await movie.search(
            .init(
                title: "Fixture",
                year: "2024",
                mediaType: "movie"
            )
        )

        try require(
            byTitle.count == 1,
            "Title/year search"
        )

        let wrongYear = try await movie.search(
            .init(
                title: "Fixture",
                year: "1990",
                mediaType: "movie"
            )
        )

        try require(
            wrongYear.isEmpty,
            "Search year filter"
        )

        for voice in ["a", "b"] {
            let result = try await movie.playback(
                for: .init(
                    media: media,
                    sourceID: "one",
                    translationID: voice
                )
            )

            try require(
                result.url.path == "/\(voice)/movie.m3u8",
                "Movie translation mapping"
            )

            try require(
                result.translationName == "Voice \(voice)",
                "Translation metadata"
            )

            if voice == "b" {
                try require(
                    result.quality == "1080p" &&
                    result.expiresAt != nil,
                    "Deferred source metadata"
                )
            }
        }

        print(
            "PASS movie, TMDB/title/year search, multiple translations"
        )

        let seriesMedia = MediaItem.parse([
            "id": .string("42"),
            "media_type": .string("tv")
        ])

        let series = AtodoProvider(
            client: FixtureAPI(series: true)
        )
        let seriesSources = try await series.sources(for: seriesMedia)
        try require(seriesSources.0.mediaType == "tv" && seriesSources.1.map(\.id) == ["one"],
                    "Series details and sources use ATODO")

        for voice in ["a", "b"] {
            for episode in ["1", "2", "3"] {
                let result = try await series.playback(
                    for: .init(
                        media: seriesMedia,
                        sourceID: "one",
                        translationID: voice,
                        season: "1",
                        episode: episode
                    )
                )

                try require(
                    result.url.path ==
                        "/\(voice)/\(episode).m3u8",
                    "Series episode mapping"
                )

                try require(
                    result.season == "1" &&
                    result.episode == episode,
                    "Episode metadata"
                )
            }
        }

        do {
            _ = try await series.playback(
                for: .init(
                    media: seriesMedia,
                    sourceID: "one",
                    translationID: "a",
                    season: "1",
                    episode: "99"
                )
            )

            throw TestFailure(
                message:
                    "Missing episode must never play another episode"
            )
        } catch ProviderError.selectionUnavailable {
        }

        print(
            "PASS series, three episodes, two voices, missing episode"
        )

        let source = try await movie.playback(
            for: .init(
                media: media,
                sourceID: "one",
                translationID: "a"
            )
        )

        let valid = PlaybackSourceValidator(
            transport: FixtureProbe()
        )

        try await valid.validate(source)

        try await PlaybackSourceValidator(
            transport: FixtureProbe(
                headStatus: 405
            )
        ).validate(source)

        for status in [401, 403, 404, 410, 500, 503] {
            do {
                try await PlaybackSourceValidator(
                    transport: FixtureProbe(
                        headStatus: status
                    )
                ).validate(source)

                throw TestFailure(
                    message: "HTTP \(status) accepted"
                )
            } catch ProviderError.http(let actual) {
                try require(
                    actual == status,
                    "HTTP status preserved"
                )
            }
        }

        do {
            try await PlaybackSourceValidator(
                transport: FixtureProbe(
                    type: "text/html",
                    body: "<html>denied</html>"
                )
            ).validate(source)

            throw TestFailure(
                message: "HTML accepted"
            )
        } catch ProviderError.invalidContentType {
        }

        do {
            try await PlaybackSourceValidator(
                transport: FixtureProbe(
                    body: "not a playlist"
                )
            ).validate(source)

            throw TestFailure(
                message: "Invalid HLS accepted"
            )
        } catch ProviderError.invalidPlaylist {
        }

        print(
            "PASS HEAD/GET, bounded body, HTTP errors, Content-Type, HLS signature"
        )

        let failing = FixtureProvider(
            "first",
            mode: .fail
        )

        let good = FixtureProvider("second")

        let request = PlaybackRequest(
            media: media,
            season: "1",
            episode: "2",
            resumeAt: 47,
            translationName: "Voice b"
        )

        let resolver = ProviderResolver(
            providers: [failing, good],
            checker: valid
        )

        let fallback = try await resolver.resolve(
            request
        )

        try require(
            fallback.source.providerID == "second" &&
            fallback.switched,
            "Priority fallback"
        )

        try require(
            fallback.source.request.resumeAt == 47 &&
            fallback.source.episode == "2" &&
            fallback.source.translationName == "Voice b",
            "Fallback preserves selection"
        )

        let expiring = FixtureProvider(
            "expired",
            mode: .expiredFirst
        )

        let renewed = try await ProviderResolver(
            providers: [expiring],
            checker: valid
        ).resolve(request)

        try require(
            renewed.source.url.path.hasSuffix("/2.m3u8"),
            "Expired URL fetched again"
        )

        try require(
            await expiring.calls == 2,
            "Exactly one renewal"
        )

        let slow = FixtureProvider(
            "slow",
            mode: .slow
        )

        let timed = try await ProviderResolver(
            providers: [slow, good],
            checker: valid,
            timeout: 0.05
        ).resolve(request)

        try require(
            timed.source.providerID == "second",
            "Timeout fallback"
        )

        print(
            "PASS unavailable provider, expired URL renewal, timeout fallback"
        )

        let first = FixtureProvider("first")

        let runtimeResolver = ProviderResolver(
            providers: [first, good],
            checker: valid
        )

        let initial = try await runtimeResolver.resolve(
            request
        )

        let recovered = try await runtimeResolver.recover(
            initial.source,
            request: initial.source.request,
            excluding: [],
            allowRenewal: false
        )

        try require(
            recovered.source.providerID == "second",
            "Runtime AVPlayer failure advances provider"
        )

        // Cinemap now uses the configured authorized Video API, not a built-in debug stream.
        let configured = CinemapProvider(baseURL: URL(string: "https://fixture.invalid/video")!)
        try require(configured.availability == .available, "Configured Cinemap available")
        let configuredSources = try await configured.sources(for: media)
        try require(configuredSources.1.first?.id == "cinemap", "Configured Cinemap source")
        let configuredRequests = try await configured.requests(for: request)
        try require(configuredRequests.first?.providerID == "cinemap", "Cinemap request identity")
        let downloads = try await good.downloads(for: request)
        try require(downloads.isEmpty, "Streaming provider does not imply download permission")
        let priority = try await ProviderResolver(providers: [first, good], checker: valid).resolve(request)
        let reversedPriority = try await ProviderResolver(providers: [good, first], checker: valid).resolve(request)
        try require(priority.source.providerID == "first" && reversedPriority.source.providerID == "second", "Provider priority order")
        print("ALL PROVIDER TESTS PASSED (fixtures, download policy and persistence)")
    }
}
