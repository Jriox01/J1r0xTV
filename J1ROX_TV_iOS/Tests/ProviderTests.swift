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
                "streams": .object(["video": .object(["hls": .object([
                    "master": .string("https://fixture.invalid/\(voice)/movie.m3u8")
                ])])]),
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
                                    "season_id": .number(1),
                                    "episodes": .array(
                                        ["1", "2", "3"].map { episode in
                                            .object([
                                                "episode_id": .string(episode),
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
        try await runSeriesTests()
        try runContinueWatchingTests()
        try await runWatchTogetherTests()
        try await runDownloadTests()
        try await runZonaTests()
        try await runCDNTests()
        try require(APIConfig.baseURL.absoluteString == "https://api.atodo.fun/", "ATODO API base")
        let defaults = ProviderResolver().providers
        try require(defaults.map(\.id) == ["atodo", "zona", "cdnvideohub"] && defaults.allSatisfy { $0.availability == .available },
                    "Atodo, Zona and CDN VideoHub are registered; unconfigured Cinemap is not advertised")

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
        // Same response structure as ATODO streams.video.http.qualities;
        // signed endpoints have no file extension. Credentials stay in fixtures.
        let signedURL = "https://fixture.invalid/?expires=9999999999&token=fixture"
        let extensionless = try await movie.resolve(.init(media: media, sourceID: "one"), container: [
            "streams": .object(["video": .object(["http": .object([
                "qualities": .object(["720": .string(signedURL), "144": .string(signedURL + "&low=1")])
            ])])])
        ])
        try require(extensionless.url.absoluteString == signedURL, "ATODO extensionless MP4 preserves signature and selects highest quality")

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

@MainActor private func runZonaTests() async throws {
    let media = MediaItem.parse(["id": .string("157336"), "title": .string("Интерстеллар"), "year": .string("2014")])
    let row: [String: JSONValue] = ["slug": .string("interstellar"), "title": .string("Интерстеллар"), "year": .number(2014), "type": .string("movie")]
    try require(ZonaProvider.matches(row, media: media), "Zona exact movie match")
    var wrong = row; wrong["year"] = .number(2024)
    try require(!ZonaProvider.matches(wrong, media: media), "Zona rejects remakes with another year")
    wrong = row; wrong["type"] = .string("series")
    try require(!ZonaProvider.matches(wrong, media: media), "Zona rejects wrong media type")
    try require(try ZonaProvider.episodeKey(season: "2", episode: "11") == "S02E11", "Zona episode identifier")
    do { _ = try ZonaProvider.episodeKey(season: "2", episode: nil); throw TestFailure(message: "Missing episode accepted") }
    catch ProviderError.selectionUnavailable {}
    func batch(_ url: String, format: String = "HLS", transform: String = "") -> JSONValue {
        .object(["extractorType": .object(["id": .number(1), "name": .string("Fixture")]),
                 "videoStreams": .array([.object(["source": .object(["url": .string(url), "headers": .object(["Referer": .string("https://example.com/")])]),
                    "translation": .string("Дубляж"), "resolution": .string(format), "parameters": .object(["urlTransform": .string(transform)])])])])
    }
    try require(ZonaProvider.streams([batch("https://example.com/movie.m3u8")]).count == 1, "Zona HLS accepted")
    try require(ZonaProvider.streams([batch("https://example.com/movie.mp4", format: "1080p")]).count == 1, "Zona MP4 quality label accepted")
    try require(ZonaProvider.streams([batch("https://example.com/movie.mpd", format: "DASH")]).isEmpty, "Zona DASH not passed to AVPlayer")
    try require(ZonaProvider.streams([batch("http://example.com/movie.m3u8")]).isEmpty, "Zona does not weaken ATS")
    try require(ZonaProvider.streams([batch("https://example.com/movie.m3u8", transform: "unsupported")]).isEmpty, "Transform-required streams excluded")
    let fixture = batch("https://example.com/movie.m3u8")
    let provider = ZonaProvider(fetch: { path, _ in
        if path == "search" { return .object(["data": .array([.object(row)])]) }
        return .object(["data": .object(["kp_id": .number(258687), "slug": .string("interstellar")])])
    }, streamLoader: { kp, episode in
        guard kp == "258687", episode == nil else { throw ProviderError.invalidResponse }
        return [fixture]
    })
    let content = try await provider.content(for: media, sourceID: "zona")
    let voice = provider.translations(in: content)[0]
    let request = PlaybackRequest(media: media, sourceID: "zona", translationID: voice.id, translationName: voice.name, providerID: "zona")
    let playback = try await provider.playback(for: request)
    try require(playback.providerID == "zona" && playback.request.media.id == "157336", "Zona keeps original TMDB identity")
    try require(playback.headers["Referer"] == "https://example.com/", "Zona preserves declared request headers")
    var unavailable = request; unavailable.translationID = "missing"
    do { _ = try await provider.playback(for: unavailable); throw TestFailure(message: "Zona changed voice silently") }
    catch ProviderError.selectionUnavailable {}
    let service = StreamingService(resolver: ProviderResolver(providers: [AtodoProvider(client: FixtureAPI(series: false)), provider]))
    let sources = try await service.sources(for: media)
    try require(sources.1.map(\.id) == ["one", "zona"], "Aggregate sources from both providers")
    _ = try await service.content(for: media, sourceID: "zona")
    try require(service.providerID == "zona", "Source routes to Zona")
    print("PASS Zona matching, episode identity, native stream filtering, source routing and explicit voice")
}

@MainActor private func runCDNTests() async throws {
    let media = MediaItem.parse(["id": .string("1396"), "title": .string("Fixture series"), "year": .string("2008"), "media_type": .string("tv")])
    let rows: [JSONValue] = [
        .object(["vkId": .string("101"), "season": .number(1), "episode": .number(11), "voiceStudio": .string("Studio A")]),
        .object(["vkId": .string("202"), "season": .number(2), "episode": .number(11), "voiceStudio": .string("Studio A")]),
        .object(["vkId": .string("203"), "season": .number(2), "episode": .number(11), "voiceStudio": .string("Studio B")])
    ]
    let provider = CDNVideoHubProvider(identify: { item in
        guard item.id == "1396" else { throw ProviderError.mediaNotFound }
        return "404"
    }, fetch: { path, query in
        if path == "playlist" {
            guard query["id"] == "404" else { throw ProviderError.invalidResponse }
            return .object(["isSerial": .bool(true), "items": .array(rows)])
        }
        guard path == "video/202" else { throw ProviderError.selectionUnavailable }
        return .object(["sources": .object(["hlsUrl": .string("https://example.com/series.m3u8")])])
    })
    let content = try await provider.content(for: media, sourceID: provider.id)
    let voice = provider.translations(in: content).first { $0.name == "Studio A" }!
    try require(provider.seasons(in: voice).count == 2, "CDN lists seasons per voice")
    let request = PlaybackRequest(media: media, sourceID: provider.id, translationID: voice.id, season: "2", episode: "11", translationName: voice.name, providerID: provider.id)
    let source = try await provider.playback(for: request)
    try require(source.url.absoluteString == "https://example.com/series.m3u8" && source.request.media.id == "1396", "CDN maps TMDB separately and selects S02E11")
    var unavailable = request; unavailable.translationID = "missing"
    do { _ = try await provider.playback(for: unavailable); throw TestFailure(message: "CDN silently changed voice") }
    catch ProviderError.selectionUnavailable {}
    unavailable = request; unavailable.episode = "12"
    do { _ = try await provider.playback(for: unavailable); throw TestFailure(message: "CDN silently changed episode") }
    catch ProviderError.selectionUnavailable {}
    print("PASS CDN VideoHub identity, per-voice seasons and strict episode selection")
}
