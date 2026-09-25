import Foundation

private struct WatchTogetherTestFailure: Error { let message: String }
private func expectTogether(_ condition: Bool, _ message: String) throws {
    if !condition { throw WatchTogetherTestFailure(message: message) }
}

private struct TogetherTestChecker: PlaybackSourceChecking {
    func validate(_ source: PlaybackSource) async throws {}
}

// Test-only provider exercises the production resolver without contacting a media service.
private struct TogetherTestProvider: VideoProvider {
    let id = "available-provider"
    let name = "Test provider"
    let availability = ProviderAvailability.available
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) { (item, []) }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] { [:] }
    func translations(in content: [String: JSONValue]) -> [TranslationOption] { [] }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { [] }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { [] }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        var value = request; value.providerID = id; value.sourceID = "available-source"
        return [value]
    }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        guard request.sourceID == "available-source", request.season == "2", request.episode == "5",
              request.translationName == nil || request.translationName == "Available voice" else {
            throw ProviderError.selectionUnavailable
        }
        var value = request; value.translationID = "available-voice"; value.translationName = "Available voice"
        return PlaybackSource(request: value, url: URL(string: "https://test.invalid/device-local-token.mp4")!, providerID: id, providerName: name)
    }
}

func runWatchTogetherTests() async throws {
    let media = MediaItem.parse(["id": .string("42"), "title": .string("Protocol test"), "media_type": .string("tv")])
    var request = PlaybackRequest(media: media, sourceID: "source-a", translationID: "voice-a", season: "2", episode: "5",
                                  translationName: "Original voice", providerID: "provider-a")
    let original = WatchTogetherContent(request)
    request.sourceID = "source-b"; request.translationName = "Another voice"
    let variant = WatchTogetherContent(request)
    try expectTogether(original.playbackID == variant.playbackID, "source and voice changes retain coordinated timeline identity")
    try expectTogether(original.coordinationID != variant.coordinationID, "different source/dub must not coordinate until both peers finish switching")
    request.episode = "6"
    let next = WatchTogetherContent(request)
    try expectTogether(original.playbackID != next.playbackID, "different episodes cannot share playback identity")
    request.season = nil
    try expectTogether(!WatchTogetherContent(request).isValid, "incomplete series selection is rejected")

    let message = WatchTogetherMessage(event: .changeEpisode, revision: .init(counter: 1, author: "a"), content: next)
    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(WatchTogetherMessage.self, from: encoded)
    try expectTogether(decoded.content == next && decoded.revision == message.revision, "wire format round trip")
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let content = object["content"] as! [String: Any]
    let allowed: Set<String> = ["mediaID", "title", "mediaType", "season", "episode", "providerID", "sourceID", "voiceID", "voiceName"]
    try expectTogether(Set(content.keys).isSubset(of: allowed), "wire content carries only catalog identifiers, never URLs or headers")

    var a = WatchTogetherState(content: original), b = WatchTogetherState(content: original)
    try expectTogether(a.publish(next, author: "a"), "local next episode publishes once")
    try expectTogether(!a.publish(next, author: "a"), "duplicate automatic next episode does not publish again")
    try expectTogether(b.receive(message), "peer applies next episode")
    try expectTogether(!b.receive(message), "duplicate message does not reload or advance again")
    try expectTogether(!b.publish(next, author: "b"), "applying a received value cannot create an echo")
    let stale = WatchTogetherMessage(event: .snapshot, revision: .initial, content: original)
    try expectTogether(!b.receive(stale) && b.content == next, "late stale snapshot cannot roll back a newer episode")
    let simultaneous = WatchTogetherMessage(event: .changeVoice, revision: .init(counter: 1, author: "b"), content: variant)
    _ = a.receive(simultaneous); _ = b.receive(simultaneous)
    _ = a.receive(message); _ = b.receive(message)
    try expectTogether(a.content == b.content && a.content == variant, "concurrent changes converge regardless of delivery order")
    var late = WatchTogetherState(content: original)
    _ = late.receive(.init(event: .snapshot, revision: a.revision, content: variant))
    try expectTogether(late.content == variant, "late participant adopts latest complete selection")
    try expectTogether(late.publish(next, author: "c") && late.revision.counter == 2, "local clock advances after remote state")
    var rejoined = WatchTogetherState(content: next, revision: late.revision)
    try expectTogether(!rejoined.receive(stale) && rejoined.content == next,
                       "version persisted in GroupActivity protects rejoin even after the original author leaves")
    let unchanged = WatchTogetherMessage(event: .snapshot, revision: rejoined.revision, content: next)
    try expectTogether(!rejoined.receive(unchanged) && rejoined.revision == unchanged.revision,
                       "equal initial snapshot confirms content without reload or outgoing change")

    let ids = [UUID(), UUID(), UUID()]
    let owner = WatchTogetherState.automaticAdvanceOwner(in: Set(ids))
    try expectTogether(owner == WatchTogetherState.automaticAdvanceOwner(in: Set(ids.reversed())), "three participants elect the same countdown owner")
    try expectTogether(WatchTogetherState.automaticAdvanceOwner(in: Set(ids.filter { $0 != owner })) != owner, "owner departure elects a remaining participant")

    var current = original.request(media: media, resumeAt: 120)
    current.translationName = "Available voice"
    let resolver = WatchTogetherResolver(resolver: ProviderResolver(providers: [TogetherTestProvider()], checker: TogetherTestChecker(), timeout: 1))
    current.providerID = "available-provider"; current.sourceID = "available-source"
    let selected = WatchTogetherContent(current)
    let resolved = try await resolver.resolve(selected, current: current, position: 120)
    try expectTogether(resolved.request.season == "2" && resolved.request.episode == "5" && resolved.request.resumeAt == 120,
                       "exact selection resolves independently and preserves local preparation position")
    try expectTogether(selected.matches(resolved.request), "same named voice may have a refreshed opaque ID")
    try expectTogether(selected.coordinationID == WatchTogetherContent(resolved.request).coordinationID,
                       "refreshed voice ID and CDN URL do not change coordination identity")
    do {
        _ = try await resolver.resolve(original, current: current, position: 0)
        throw WatchTogetherTestFailure(message: "missing provider silently substituted")
    } catch is ProviderError {}
    var missingSource = current; missingSource.sourceID = "missing"
    do {
        _ = try await resolver.resolve(WatchTogetherContent(missingSource), current: current, position: 0)
        throw WatchTogetherTestFailure(message: "missing source silently substituted")
    } catch is ProviderError {}
    var missingVoice = current; missingVoice.translationName = "Missing voice"
    do {
        _ = try await resolver.resolve(WatchTogetherContent(missingVoice), current: current, position: 0)
        throw WatchTogetherTestFailure(message: "missing voice silently substituted")
    } catch is ProviderError {}
    var missingEpisode = current; missingEpisode.episode = "6"
    do {
        _ = try await resolver.resolve(WatchTogetherContent(missingEpisode), current: current, position: 0)
        throw WatchTogetherTestFailure(message: "missing episode silently substituted")
    } catch is ProviderError {}
    print("PASS WatchTogetherTests: wire format, identities, duplicate/stale events, concurrent ordering, late join/rejoin, owner election, strict selection")
}
