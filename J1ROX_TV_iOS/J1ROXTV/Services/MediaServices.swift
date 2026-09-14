import Foundation

// Detail selectors use the first available provider; playback is always resolved afresh.
@MainActor final class StreamingService {
    let resolver: ProviderResolver
    private var activeProvider: any VideoProvider
    var providerID: String { activeProvider.id }
    var providerName: String { activeProvider.name }

    init(resolver: ProviderResolver = ProviderResolver()) {
        self.resolver = resolver
        activeProvider = resolver.providers.first ?? AtodoProvider()
    }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        for provider in resolver.providers where provider.availability == .available {
            do {
                let result = try await withProviderTimeout(seconds: resolver.timeout) {
                    try await provider.sources(for: item)
                }
                guard !result.1.isEmpty else { continue }
                activeProvider = provider
                return result
            } catch { try Task.checkCancellation() }
        }
        throw ProviderError.unavailable
    }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        try await activeProvider.content(for: item, sourceID: sourceID)
    }
    func translations(in object: [String: JSONValue]) -> [TranslationOption] { activeProvider.translations(in: object) }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { activeProvider.seasons(in: translation) }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { activeProvider.episodes(in: season) }
    func resolve(_ request: PlaybackRequest) async throws -> PlaybackSelection {
        let result = try await resolver.resolve(request)
        return PlaybackSelection(source: result.source, switched: result.switched)
    }
}
