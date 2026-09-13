package tv.j1r0x.app.data.provider.rezka

/** Adapter-neutral models. They intentionally make no assumptions about JSON field names. */
data class RezkaMediaResult(
    val id: String,
    val mediaType: RezkaMediaType,
    val title: String,
    val originalTitle: String? = null,
    val year: String? = null,
    val imdbId: String? = null,
    val kinopoiskId: String? = null,
    val tmdbId: String? = null,
    val translations: List<RezkaTranslation> = emptyList(),
)

enum class RezkaMediaType {
    MOVIE,
    TV,
}

data class RezkaTranslation(
    val id: String? = null,
    val name: String? = null,
    val language: String? = null,
    val isOriginal: Boolean = false,
    val seasons: List<RezkaSeason> = emptyList(),
    val streams: List<RezkaStream> = emptyList(),
)

data class RezkaSeason(
    val id: String? = null,
    val number: String,
    val name: String? = null,
    val episodes: List<RezkaEpisode> = emptyList(),
)

data class RezkaEpisode(
    val id: String? = null,
    val number: String,
    val name: String? = null,
    val streams: List<RezkaStream> = emptyList(),
)

data class RezkaStream(
    val url: String,
    val type: RezkaStreamType = RezkaStreamType.UNKNOWN,
    val quality: RezkaQuality? = null,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

enum class RezkaStreamType {
    HLS,
    MP4,
    DASH,
    UNKNOWN,
}

data class RezkaQuality(
    val id: String? = null,
    val label: String,
    val height: Int? = null,
    val bitrate: Long? = null,
)

enum class RezkaHealthStatus {
    DISABLED,
    NOT_CONFIGURED,
    DOCUMENTATION_REQUIRED,
}

data class RezkaHealthResult(
    val status: RezkaHealthStatus,
    val message: String,
)
