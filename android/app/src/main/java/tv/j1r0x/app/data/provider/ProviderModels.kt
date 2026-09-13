package tv.j1r0x.app.data.provider

/** Stable identity used by every video provider. */
data class MediaIdentity(
    val tmdbId: String? = null,
    val imdbId: String? = null,
    val kinopoiskId: String? = null,
    val title: String,
    val originalTitle: String? = null,
    val year: String? = null,
    val mediaType: MediaType,
) {
    /** Exact lookup order shared by future authorised adapters; no fuzzy title match is emitted. */
    fun lookupCandidates(): List<MediaIdentityCandidate> = buildList {
        imdbId?.trim()?.takeIf { it.isNotEmpty() }?.let {
            add(MediaIdentityCandidate(MediaIdentityKey.IMDB, it))
        }
        kinopoiskId?.trim()?.takeIf { it.isNotEmpty() }?.let {
            add(MediaIdentityCandidate(MediaIdentityKey.KINOPOISK, it))
        }
        tmdbId?.trim()?.takeIf { it.isNotEmpty() }?.let {
            add(MediaIdentityCandidate(MediaIdentityKey.TMDB, it))
        }
        val exactYear = year?.trim()?.takeIf { it.isNotEmpty() }
        originalTitle?.trim()?.takeIf { it.isNotEmpty() && exactYear != null }?.let {
            add(MediaIdentityCandidate(MediaIdentityKey.ORIGINAL_TITLE_AND_YEAR, it, exactYear))
        }
        title.trim().takeIf { it.isNotEmpty() && exactYear != null }?.let {
            add(MediaIdentityCandidate(MediaIdentityKey.TITLE_AND_YEAR, it, exactYear))
        }
    }
}

data class MediaIdentityCandidate(
    val key: MediaIdentityKey,
    val value: String,
    val year: String? = null,
)

enum class MediaIdentityKey {
    IMDB,
    KINOPOISK,
    TMDB,
    ORIGINAL_TITLE_AND_YEAR,
    TITLE_AND_YEAR,
}

enum class MediaType {
    MOVIE,
    TV,
}

/**
 * Provider-independent playback choices. Values are strings because upstream
 * services may use either numeric values or opaque (but stable) identifiers.
 */
data class PlaybackRequest(
    val providerMediaId: String? = null,
    val sourceId: String? = null,
    val translationId: String? = null,
    val translationName: String? = null,
    val season: String? = null,
    val episode: String? = null,
    val preferredQuality: String? = null,
    val resumePositionMs: Long = 0L,
)

enum class ProviderStatus {
    SUCCESS,
    NOT_FOUND,
    NETWORK_ERROR,
    SERVER_ERROR,
    NO_STREAM,
    PLAYBACK_ERROR,
    DISABLED,
    INVALID_REQUEST,
    LOCAL_ERROR,
    ;

    val permitsFallback: Boolean
        get() = this == NOT_FOUND ||
            this == NETWORK_ERROR ||
            this == SERVER_ERROR ||
            this == NO_STREAM ||
            this == PLAYBACK_ERROR
}

data class ProviderMedia(
    val providerId: String,
    val providerMediaId: String,
    val mediaType: MediaType,
    val title: String,
    val originalTitle: String? = null,
    val year: String? = null,
    val translations: List<ProviderTranslation> = emptyList(),
)

data class ProviderTranslation(
    val id: String? = null,
    val name: String,
    val language: String? = null,
    val isOriginal: Boolean = false,
    val seasons: List<ProviderSeason> = emptyList(),
    val streams: List<ProviderStream> = emptyList(),
)

data class ProviderSeason(
    val id: String? = null,
    val number: String,
    val name: String? = null,
    val episodes: List<ProviderEpisode> = emptyList(),
)

data class ProviderEpisode(
    val id: String? = null,
    val number: String,
    val name: String? = null,
    val streams: List<ProviderStream> = emptyList(),
)

data class ProviderStream(
    val url: String,
    val type: ProviderStreamType = ProviderStreamType.UNKNOWN,
    val quality: ProviderQuality? = null,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

enum class ProviderStreamType {
    HLS,
    MP4,
    DASH,
    UNKNOWN,
}

data class ProviderQuality(
    val id: String? = null,
    val label: String,
    val height: Int? = null,
    val bitrate: Long? = null,
)

data class ProviderResult(
    val providerId: String,
    val status: ProviderStatus,
    val sourceId: String? = null,
    val media: ProviderMedia? = null,
    val translation: ProviderTranslation? = null,
    val season: ProviderSeason? = null,
    val episode: ProviderEpisode? = null,
    val stream: ProviderStream? = null,
    val message: String? = null,
    val cause: Throwable? = null,
    val responseTimeMs: Long? = null,
    val attemptedProviderIds: Set<String> = emptySet(),
) {
    val isSuccess: Boolean
        get() = status == ProviderStatus.SUCCESS && !stream?.url.isNullOrBlank()

    companion object {
        fun success(
            providerId: String,
            stream: ProviderStream,
            sourceId: String? = null,
            media: ProviderMedia? = null,
            translation: ProviderTranslation? = null,
            season: ProviderSeason? = null,
            episode: ProviderEpisode? = null,
        ) = ProviderResult(
            providerId = providerId,
            status = ProviderStatus.SUCCESS,
            sourceId = sourceId,
            media = media,
            translation = translation,
            season = season,
            episode = episode,
            stream = stream,
        )

        fun failure(
            providerId: String,
            status: ProviderStatus,
            message: String? = null,
            cause: Throwable? = null,
        ) = ProviderResult(
            providerId = providerId,
            status = status,
            message = message,
            cause = cause,
        )
    }
}
