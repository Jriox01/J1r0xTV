import Foundation

/// Uses the existing provider pipeline; fallback never changes the requested episode.
struct WatchTogetherResolver {
    var resolver = ProviderResolver()

    func resolve(_ content: WatchTogetherContent, current: PlaybackRequest?, position: Double) async throws -> PlaybackSelection {
        guard content.isValid else { throw ProviderError.selectionUnavailable }
        let media: MediaItem
        if let current, current.media.id == content.mediaID, current.media.mediaType == content.mediaType {
            media = current.media
        } else {
            media = try await DetailsService().details(type: content.mediaType, id: content.mediaID)
        }
        let providers = resolver.providers.filter { $0.id == content.providerID } +
            resolver.providers.filter { $0.id != content.providerID }
        let ordered = ProviderResolver(providers: providers, checker: resolver.checker, timeout: resolver.timeout)
        var request = content.request(media: media, resumeAt: position)
        var attempts = [request]
        if let current, current.media.id == content.mediaID, current.media.mediaType == content.mediaType,
           current.translationName != content.voiceName {
            request.translationID = nil
            request.translationName = current.translationName
            attempts.append(request)
        }
        request.translationID = nil; request.translationName = nil
        attempts.append(request)
        for request in attempts {
            do {
                let result = try await ordered.resolve(request)
                guard WatchTogetherContent(result.source.request).playbackID == content.playbackID else {
                    throw ProviderError.selectionUnavailable
                }
                return PlaybackSelection(source: result.source, switched: result.switched)
            } catch { try Task.checkCancellation() }
        }
        throw ProviderError.selectionUnavailable
    }
}
