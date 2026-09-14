import Foundation
import AVFoundation

private struct CheckFailure: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}
private struct ProbeStub: PlaybackProbing {
    var status = 200
    var body = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\na.ts\n"
    var mime = "application/vnd.apple.mpegurl"
    func probe(_ request: URLRequest, maxBytes: Int) async throws -> PlaybackProbe {
        .init(status: status, mimeType: mime, prefix: Data(body.utf8.prefix(maxBytes)),
              finalURL: URL(string: "https://cdn.example.invalid/final.m3u8"), redirects: ["HTTP 302 fixture → cdn"])
    }
}
private actor RefreshFixture: VideoProvider {
    nonisolated let id: String
    nonisolated let name = "Fixture"
    nonisolated let availability = ProviderAvailability.available
    let failRefresh: Bool
    var refreshes = 0
    init(failRefresh: Bool = false, id: String = "fixture-refresh") { self.failRefresh = failRefresh; self.id = id }
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) { (item, []) }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] { [:] }
    nonisolated func translations(in content: [String: JSONValue]) -> [TranslationOption] { [] }
    nonisolated func seasons(in translation: TranslationOption) -> [SeasonOption] { [] }
    nonisolated func episodes(in season: SeasonOption) -> [EpisodeOption] { [] }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        var request = request; request.providerID = id; request.sourceID = "one"; return [request]
    }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        .init(request: request, url: URL(string: "https://fixture.invalid/media.m3u8")!, providerID: id, providerName: name)
    }
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource {
        refreshes += 1
        if failRefresh { throw ProviderError.forbidden }
        // Same URL can become valid again; URL inequality isn't an expiry contract.
        return try await playback(for: request)
    }
}

enum PlaybackSourceValidatorTests {
    static func run(_ source: PlaybackSource) async throws {
        let media = try await PlaybackSourceValidator(transport: ProbeStub()).inspect(source)
        try check(media.kind == .media, "media classification")
        let master = try await PlaybackSourceValidator(transport: ProbeStub(body: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\na.m3u8\n")).inspect(source)
        try check(master.kind == .master, "master classification")
        try check(master.probe.redirects.count == 1 && master.probe.finalURL?.host == "cdn.example.invalid", "redirect metadata")
        for status in [401, 403, 404, 410, 500] {
            do { try await PlaybackSourceValidator(transport: ProbeStub(status: status)).validate(source); throw CheckFailure(message: "HTTP accepted") }
            catch ProviderError.http(let actual) { try check(actual == status, "HTTP preserved") }
        }
        for mime in ["text/html", "application/json"] {
            do { try await PlaybackSourceValidator(transport: ProbeStub(body: "error", mime: mime)).validate(source); throw CheckFailure(message: "non-HLS accepted") }
            catch ProviderError.invalidContentType {}
        }
        do {
            try await PlaybackSourceValidator(transport: ProbeStub(body: "#EXTM3U-invalid\n")).validate(source)
            throw CheckFailure(message: "invalid signature accepted")
        } catch ProviderError.invalidPlaylist {}
        var expired = source; expired.expiresAt = Date(timeIntervalSinceNow: -1)
        do { try await PlaybackSourceValidator(transport: ProbeStub()).validate(expired); throw CheckFailure(message: "expired accepted") }
        catch ProviderError.expired {}
        let invalid = PlaybackSource(request: source.request, url: URL(string: "file:///tmp/test.m3u8")!, providerID: "test", providerName: "Test")
        do { try await PlaybackSourceValidator().validate(invalid); throw CheckFailure(message: "file URL accepted") }
        catch PlaybackError.invalidURL {}
        print("PASS PlaybackSourceValidatorTests: master/media, redirect metadata, HTTP errors, HTML/JSON, signature, expiry, invalid URL")
    }
}

enum TestHLSProviderTests {
    static func run(_ request: PlaybackRequest) async throws {
        for input in ["", "file:///a.m3u8", "https://", "https://user:secret@example.com/a.m3u8"] {
            do { _ = try TestHLSProvider(url: input); throw CheckFailure(message: "invalid debug URL accepted") }
            catch PlaybackError.invalidURL {}
        }
        let provider = try TestHLSProvider(url: "https://example.invalid/a.m3u8", headers: ["User-Agent": "Fixture"])
        let resolved = try await ProviderResolver(providers: [provider], checker: PlaybackSourceValidator(transport: ProbeStub())).resolve(request)
        try check(resolved.source.headers["User-Agent"] == "Fixture", "headers preserved")
        do { _ = try await provider.refresh(source: resolved.source, request: request); throw CheckFailure(message: "manual URL refresh must fail") }
        catch ProviderError.refreshUnsupported {}
        let secret = URL(string: "https://user:password@example.com/signed-secret/file?token=secret")!
        try check(!PlaybackDiagnostics.url(secret).contains("secret") && !PlaybackDiagnostics.url(secret).contains("password"), "diagnostics redact secrets")
        print("PASS TestHLSProviderTests: validation, resolver path, headers, refreshUnsupported, redaction")
    }
}

enum ProviderResolverTests {
    @MainActor static func run(_ request: PlaybackRequest) async throws {
        let provider = RefreshFixture()
        let resolver = ProviderResolver(providers: [provider], checker: PlaybackSourceValidator(transport: ProbeStub()))
        let initial = try await resolver.resolve(request)
        let renewed = try await resolver.recover(initial.source, request: initial.source.request, excluding: [])
        try check(renewed.source.url == initial.source.url && renewed.source.id != initial.source.id, "refresh may reuse URL")
        let failing = RefreshFixture(failRefresh: true)
        let failureResolver = ProviderResolver(providers: [failing], checker: PlaybackSourceValidator(transport: ProbeStub()))
        let failedSource = try await failureResolver.resolve(request)
        do { _ = try await failureResolver.recover(failedSource.source, request: failedSource.source.request, excluding: []); throw CheckFailure(message: "failed refresh accepted") }
        catch ProviderError.unavailable {}
        let backup = RefreshFixture(id: "backup")
        let fallbackResolver = ProviderResolver(providers: [failing, backup], checker: PlaybackSourceValidator(transport: ProbeStub()))
        let fallback = try await fallbackResolver.recover(failedSource.source, request: failedSource.source.request, excluding: [])
        try check(fallback.source.providerID == "backup" && fallback.switched, "refresh failure uses fallback provider")
        var expired = initial.source
        expired.expiresAt = Date(timeIntervalSinceNow: -1)
        let refreshedExpiry = try await resolver.recover(expired, request: expired.request, excluding: [])
        try check(refreshedExpiry.source.id != expired.id && refreshedExpiry.source.expiresAt == nil, "expired source uses explicit refresh")
        let session = PlaybackSession(selection: .init(source: initial.source, switched: false), resolver: resolver)
        let saved = PlaybackSnapshot(position: 47, isPlaying: false, audioLanguage: "ru", audioName: "Voice", subtitleLanguage: "en", subtitleName: "English")
        for _ in 0..<2 {
            let old = session.selection.source.id
            session.failed(sourceID: old, snapshot: saved, failure: .httpStatus(410))
            for _ in 0..<100 where session.switching { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(session.selection.source.id != old, "refresh completes")
            try check(session.selection.source.resumeState == saved, "resume position, pause, audio, subtitle preserved")
        }
        session.failed(sourceID: session.selection.source.id, snapshot: saved, failure: .httpStatus(410))
        for _ in 0..<100 where session.switching { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(session.error != nil, "retry limit terminates")
        try check(await provider.refreshes == 4, "two session refreshes plus direct and expired resolver tests")
        session.cancel()
        print("PASS ProviderResolverTests: explicit refresh, same URL, refresh failure, retry limit, resume state")
    }
}

enum PlaybackSessionTests {
    @MainActor static func run(_ source: PlaybackSource) throws {
        var expired = source; expired.expiresAt = Date(timeIntervalSinceNow: -10)
        expired.resumeState = .init(position: 47, isPlaying: false, audioName: "Voice", subtitleName: "English")
        let player = PlayerSession(source: expired)
        var failures = 0
        player.onFailure = { state, _ in
            if state.position == 47 && !state.isPlaying && state.audioName == "Voice" { failures += 1 }
        }
        player.start(); player.start()
        try check(failures == 1 && player.status == "failed", "single failure, saved state survives pre-ready expiry")
        player.stop()
        try check(player.player.currentItem == nil && player.status == "stopped", "player cleanup")
        var budget = PlaybackRetryBudget()
        try check(budget.consume() && budget.consume() && !budget.consume(), "bounded retry budget")
        print("PASS PlaybackSessionTests: expiry callback, start idempotence, pre-ready resume, cleanup, budget")
    }
}

@MainActor func runPlaybackTests() async throws {
    let media = MediaItem.parse(["id": .string("test"), "title": .string("Test")])
    let request = PlaybackRequest(media: media, sourceID: "one")
    let source = PlaybackSource(request: request, url: URL(string: "https://example.invalid/a.m3u8")!, providerID: "test", providerName: "Test")
    try await PlaybackSourceValidatorTests.run(source)
    try await TestHLSProviderTests.run(request)
    try await ProviderResolverTests.run(request)
    try PlaybackSessionTests.run(source)
}
