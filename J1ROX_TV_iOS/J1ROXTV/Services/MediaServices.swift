import Foundation
import AVFoundation

// Each source is routed to its own provider; temporary playback URLs are never cached.
@MainActor final class StreamingService {
    let resolver: ProviderResolver
    private var activeProvider: any VideoProvider
    private var sourceProviders: [String: any VideoProvider] = [:]
    private var contentGeneration = UUID()
    var providerID: String { activeProvider.id }
    var providerName: String { activeProvider.name }

    init(resolver: ProviderResolver = ProviderResolver()) {
        self.resolver = resolver
        activeProvider = resolver.providers.first ?? AtodoProvider()
    }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        let timeout = resolver.timeout
        let providers = resolver.providers
        let results = await withTaskGroup(of: (Int, [SourceOption]).self) { group in
            for (index, provider) in providers.enumerated() where provider.availability == .available && provider.canHandle(item) {
                group.addTask {
                    do { return (index, try await withProviderTimeout(seconds: timeout) { try await provider.sources(for: item) }.1) }
                    catch { return (index, []) }
                }
            }
            var results: [(Int, [SourceOption])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        var options: [SourceOption] = []
        var routes: [String: any VideoProvider] = [:]
        for (index, values) in results {
            for value in values where routes[value.id] == nil {
                options.append(value); routes[value.id] = providers[index]
            }
        }
        guard let first = options.first, let provider = routes[first.id] else { throw ProviderError.unavailable }
        sourceProviders = routes; activeProvider = provider
        return (item, options)
    }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        guard let provider = sourceProviders[sourceID] else { throw ProviderError.selectionUnavailable }
        let generation = UUID(); contentGeneration = generation
        let content = try await withProviderTimeout(seconds: provider.resolutionTimeout ?? resolver.timeout) {
            try await provider.content(for: item, sourceID: sourceID)
        }
        try Task.checkCancellation()
        guard contentGeneration == generation else { throw CancellationError() }
        activeProvider = provider
        return content
    }
    func translations(in object: [String: JSONValue]) -> [TranslationOption] { activeProvider.translations(in: object) }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { activeProvider.seasons(in: translation) }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { activeProvider.episodes(in: season) }
    func resolve(_ request: PlaybackRequest) async throws -> PlaybackSelection {
        let result = try await resolver.resolve(request)
        return PlaybackSelection(source: result.source, switched: result.switched)
    }
    // Explicit user selections must not silently resolve another source or voice.
    func resolveSelected(_ request: PlaybackRequest) async throws -> PlaybackSelection {
        guard let provider = resolver.providers.first(where: { $0.id == request.providerID }) else { throw ProviderError.selectionUnavailable }
        let checker = resolver.checker
        let source = try await withProviderTimeout(seconds: provider.resolutionTimeout ?? resolver.timeout) {
            let source = try await provider.playback(for: request)
            try await checker.validate(source)
            return source
        }
        return PlaybackSelection(source: source)
    }
    func downloads(_ request: PlaybackRequest) async throws -> (PlaybackRequest, [DownloadVariant]) {
        // Resolve the selected provider/episode without downloading a fallback voice.
        let source = try await resolveSelected(request).source
        let variant = DownloadVariant(url: source.url, quality: source.quality ?? "Оригинал",
            expectedBytes: nil, headers: source.headers, expiresAt: source.expiresAt)
        guard variant.isValid else { throw DownloadError.unavailable }
        var options: [String: Any] = [:]
        if !source.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers }
        if let agent = source.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        let asset = AVURLAsset(url: source.url, options: options)
        guard try await asset.load(.hasProtectedContent) == false else { throw DownloadError.unavailable }
        if variant.isHLS {
            var request = URLRequest(url: source.url, timeoutInterval: 15)
            request.allHTTPHeaderFields = source.headers
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let manifest = String(data: data, encoding: .utf8),
                  manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw DownloadError.invalidFile }
            return (source.request, variant.hlsVariants(manifest: manifest))
        }
        do {
            let advertised = try await activeProvider.downloads(for: source.request).filter(\.isValid)
            if !advertised.isEmpty { return (source.request, advertised) }
        } catch { try Task.checkCancellation() }
        return (source.request, [try await variant.inspectingSize()])
    }
}
