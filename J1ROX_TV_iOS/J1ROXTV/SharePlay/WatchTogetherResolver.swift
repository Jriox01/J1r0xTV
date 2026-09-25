import Foundation

/// Each iPhone resolves its own URL. Shared viewing requires the same source and dub.
struct WatchTogetherResolver: Sendable {
    var resolver = ProviderResolver()

    func resolve(_ content: WatchTogetherContent, current: PlaybackRequest?, position: Double) async throws -> PlaybackSelection {
        guard content.isValid else { throw ProviderError.selectionUnavailable }
        let media: MediaItem
        if let current, current.media.id == content.mediaID, current.media.mediaType == content.mediaType {
            media = current.media
        } else {
            media = try await DetailsService().details(type: content.mediaType, id: content.mediaID)
        }
        guard let provider = resolver.providers.first(where: { $0.id == content.providerID }),
              provider.availability == .available, provider.canHandle(media) else {
            throw ProviderError.selectionUnavailable
        }
        let request = content.request(media: media, resumeAt: position)
        let source = try await withProviderTimeout(seconds: resolver.timeout) {
            // Do not call requests(for:): it intentionally enumerates fallback sources for solo playback.
            let source = try await provider.playback(for: request)
            guard source.providerID == content.providerID, content.matches(source.request),
                  !source.url.isFileURL else { throw ProviderError.selectionUnavailable }
            guard source.expiresAt.map({ $0 > Date() }) ?? true else { throw ProviderError.expired }
            try await resolver.checker.validate(source)
            return source
        }
        try Task.checkCancellation()
        return PlaybackSelection(source: source)
    }
}
