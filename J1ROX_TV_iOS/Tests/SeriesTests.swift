import Foundation

private struct SeriesFailure: Error { let message: String }
private func expectSeries(_ condition: Bool, _ message: String) throws {
    if !condition { throw SeriesFailure(message: message) }
}

// Test-only provider; production continues to use real ATODO responses.
private struct SeriesFixture: VideoProvider {
    let id = "series-test"
    let name = "Series test"
    let availability = ProviderAvailability.available
    let parser = AtodoProvider()
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        (item, [.init(id: "one", name: "1"), .init(id: "slow", name: "2"), .init(id: "fast", name: "3")])
    }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        if sourceID == "slow" { try await Task.sleep(nanoseconds: 100_000_000) }
        func season(_ number: String, _ episodes: [String]) -> JSONValue {
            .object(["season_number": .string(number), "episodes": .array(episodes.map {
                .object(["episode_number": .string($0)])
            })])
        }
        return ["translations": .array(["First", "Second"].map {
            .object(["id": .string($0), "name": .string($0), "seasons": .array([
                season("2", ["1"]), season("1", ["2", "1"])
            ])])
        })]
    }
    func translations(in value: [String: JSONValue]) -> [TranslationOption] { parser.translations(in: value) }
    func seasons(in value: TranslationOption) -> [SeasonOption] { parser.seasons(in: value) }
    func episodes(in value: SeasonOption) -> [EpisodeOption] { parser.episodes(in: value) }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] { [request] }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource { throw ProviderError.unavailable }
}

@MainActor func runSeriesTests() async throws {
    let item = MediaItem.parse(["id": .string(UUID().uuidString), "media_type": .string("tv")])
    let key = "voice.tv.\(item.id)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    func model() -> DetailsViewModel {
        DetailsViewModel(item: item, streaming: StreamingService(resolver: ProviderResolver(providers: [SeriesFixture()])))
    }
    let first = model()
    await first.prepare()
    try expectSeries(first.selectedTranslation?.name == "First", "first API voice is the default")
    try expectSeries(first.selectedSeason?.number == "1" && first.episodes.map(\.number) == ["1", "2"], "initial season and ordered episodes")
    first.selectedEpisode = "2"
    first.select(translation: first.translations[1])
    try expectSeries(first.selectedEpisode == "2" && first.selectedSeason?.number == "1", "voice change preserves episode")
    let reopened = model()
    await reopened.prepare()
    try expectSeries(reopened.selectedTranslation?.name == "Second", "per-content voice restored")
    UserDefaults.standard.set("Removed voice", forKey: key)
    let removed = model()
    await removed.prepare()
    try expectSeries(removed.selectedTranslation?.name == "First", "missing voice falls back to first")
    var request = PlaybackRequest(media: item, season: "1", episode: "1")
    try expectSeries(first.next(after: request)?.1.number == "2", "next episode")
    request.episode = "2"
    try expectSeries(first.next(after: request)?.0.number == "2" && first.next(after: request)?.1.number == "1", "next season")
    request.season = "2"; request.episode = "1"
    try expectSeries(first.next(after: request) == nil, "final episode has no successor")
    request.sourceID = first.activeSource; request.providerID = "series-test"
    request.translationID = first.selectedTranslation?.id; request.translationName = first.selectedTranslation?.name
    try expectSeries(first.isFinalAvailableEpisode(request) == true, "known final season/episode confirms completion")
    request.season = "1"; request.episode = "1"
    try expectSeries(first.isFinalAvailableEpisode(request) == false && first.next(after: request)?.1.number == "2",
                     "ordinary episode retains series and successor")
    request.episode = "2"
    try expectSeries(first.isFinalAvailableEpisode(request) == false && first.next(after: request)?.0.number == "2",
                     "season end retains series with next season")
    request.episode = "missing"
    try expectSeries(first.isFinalAvailableEpisode(request) == nil, "unknown episode is not proof of completion")
    request.season = "2"; request.episode = "1"
    first.error = "Network unavailable"
    try expectSeries(first.isFinalAvailableEpisode(request) == nil, "failed metadata must not erase series")
    first.error = nil
    first.select(season: first.seasons[1])
    try expectSeries(first.episodes.map(\.number) == ["1"], "season replaces old episode list")
    let old = Task { try await first.select(source: .init(id: "slow", name: "2")) }
    try await Task.sleep(nanoseconds: 10_000_000)
    try await first.select(source: .init(id: "fast", name: "3"))
    do { try await old.value; throw SeriesFailure(message: "stale source accepted") }
    catch is CancellationError {}
    try expectSeries(first.activeSource == "fast", "latest source wins")
    let incomingMedia = MediaItem.parse(["id": .string(UUID().uuidString), "media_type": .string("tv")])
    await first.synchronize(.init(media: incomingMedia, sourceID: "one", translationID: "different-device-id",
                                 season: "1", episode: "2", translationName: "Second"))
    try expectSeries(first.item.id == incomingMedia.id && first.activeSource == "one", "incoming media reloads old player selectors")
    try expectSeries(first.selectedTranslation?.name == "Second" && first.selectedEpisode == "2",
                     "incoming voice matches by name when device IDs differ")
    first.select(translation: .init(id: "empty", name: "Empty", payload: [:]), remember: false)
    try expectSeries(first.seasons.isEmpty && first.episodes.isEmpty && first.selectedEpisode == nil, "empty API clears selectors")
    print("PASS SeriesTests: voice defaults/persistence, season/episode retention, succession, stale requests, empty content")
}
