package tv.j1r0x.app.data.provider

import kotlinx.serialization.json.JsonObject
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.domain.model.PlaybackSelection
import tv.j1r0x.app.utils.text

fun MediaItem.toMediaIdentity(): MediaIdentity {
    val externalIds = raw["external_ids"] as? JsonObject
    return MediaIdentity(
        tmdbId = raw.text("tmdb_id", "id").ifBlank { id }.takeIf { it.isNotBlank() },
        imdbId = raw.text("imdb_id")
            .ifBlank { externalIds?.text("imdb_id").orEmpty() }
            .takeIf { it.isNotBlank() },
        kinopoiskId = raw.text("kinopoisk_id", "kp_id").takeIf { it.isNotBlank() },
        title = title,
        originalTitle = originalTitle.takeIf { it.isNotBlank() },
        year = year.takeIf { it.isNotBlank() },
        mediaType = if (type == "tv") MediaType.TV else MediaType.MOVIE,
    )
}

fun PlaybackSelection.toPlaybackRequest(): PlaybackRequest = PlaybackRequest(
    providerMediaId = providerMediaId,
    sourceId = sourceId.takeIf { it.isNotBlank() },
    translationId = translationId.takeIf { it.isNotBlank() },
    translationName = translationName.takeIf { it.isNotBlank() },
    season = season.takeIf { it.isNotBlank() },
    episode = episode.takeIf { it.isNotBlank() },
    resumePositionMs = resumePositionMs,
)

fun ProviderResult.toPlaybackSelection(
    item: MediaItem,
    request: PlaybackRequest,
    fallbackAttempted: Boolean = false,
): PlaybackSelection? {
    val resolvedStream = stream?.url?.takeIf { it.isNotBlank() } ?: return null
    return PlaybackSelection(
        item = item,
        sourceId = sourceId.orEmpty().ifBlank { request.sourceId.orEmpty() },
        translationName = translation?.name.orEmpty().ifBlank { request.translationName.orEmpty() },
        season = season?.number.orEmpty().ifBlank { request.season.orEmpty() },
        episode = episode?.number.orEmpty().ifBlank { request.episode.orEmpty() },
        streamUrl = resolvedStream,
        resumePositionMs = request.resumePositionMs,
        providerId = providerId,
        providerMediaId = media?.providerMediaId.orEmpty()
            .ifBlank { request.providerMediaId.orEmpty() }
            .ifBlank { item.id },
        translationId = translation?.id.orEmpty().ifBlank { request.translationId.orEmpty() },
        attemptedProviderIds = attemptedProviderIds,
        fallbackAttempted = fallbackAttempted,
        streamHeaders = stream?.headers.orEmpty(),
    )
}
