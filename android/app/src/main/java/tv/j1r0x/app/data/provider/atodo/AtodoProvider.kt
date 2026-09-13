package tv.j1r0x.app.data.provider.atodo

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import tv.j1r0x.app.data.api.ApiHttpException
import tv.j1r0x.app.data.provider.MediaIdentity
import tv.j1r0x.app.data.provider.MediaType
import tv.j1r0x.app.data.provider.PlaybackRequest
import tv.j1r0x.app.data.provider.ProviderEpisode
import tv.j1r0x.app.data.provider.ProviderMedia
import tv.j1r0x.app.data.provider.ProviderQuality
import tv.j1r0x.app.data.provider.ProviderResult
import tv.j1r0x.app.data.provider.ProviderSeason
import tv.j1r0x.app.data.provider.ProviderStatus
import tv.j1r0x.app.data.provider.ProviderStream
import tv.j1r0x.app.data.provider.ProviderStreamType
import tv.j1r0x.app.data.provider.ProviderTranslation
import tv.j1r0x.app.data.provider.VideoProvider
import tv.j1r0x.app.data.repository.MediaRepository
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.domain.model.SourceOption
import tv.j1r0x.app.utils.collection
import tv.j1r0x.app.utils.streamUrls
import tv.j1r0x.app.utils.text
import tv.j1r0x.app.utils.translationDisplayName

/**
 * Provider adapter for the existing Atodo repository.
 *
 * It deliberately delegates every HTTP request and the episode.data Base64
 * flow to [MediaRepository], so Atodo's established parameters, cookies,
 * headers and retry policy remain unchanged.
 */
class AtodoProvider(
    private val mediaRepository: MediaRepository,
) : VideoProvider {
    override val id: String = ID
    override val displayName: String = "Atodo"
    override val priority: Int = 10
    override val enabled: Boolean = true

    override suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult = try {
        resolveInternal(identity, request)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: ApiHttpException) {
        httpFailure(error)
    } catch (error: IOException) {
        failure(ProviderStatus.NETWORK_ERROR, error.message, error)
    } catch (error: Exception) {
        failure(ProviderStatus.LOCAL_ERROR, error.message, error)
    }

    private suspend fun resolveInternal(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        val providerMediaId = request.providerMediaId
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: identity.tmdbId?.trim()?.takeIf(String::isNotEmpty)
            ?: return failure(
                ProviderStatus.INVALID_REQUEST,
                "Atodo requires a TMDB media id",
            )
        val mediaType = identity.mediaType.toAtodoType()

        // Loading details first is mandatory for TV because MediaRepository
        // builds one canonical_info and reuses it for source/list and source/id.
        val details = mediaRepository.details(mediaType, providerMediaId)
        val (fullItem, sources) = mediaRepository.sources(details)
        if (sources.isEmpty()) {
            return failure(ProviderStatus.NO_STREAM, "Atodo returned no sources")
        }

        val orderedSources = sources.prefer(request.sourceId) { it.id }
        var lastFailure: ProviderResult? = null
        for (source in orderedSources) {
            val resolved = try {
                resolveSource(fullItem, source, identity, request)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: ApiHttpException) {
                httpFailure(error)
            } catch (error: IOException) {
                failure(ProviderStatus.NETWORK_ERROR, error.message, error)
            } catch (error: Exception) {
                // An unexpected local mapping/programming failure is critical;
                // ProviderManager must not silently mask it with another provider.
                return failure(ProviderStatus.LOCAL_ERROR, error.message, error)
            }

            if (resolved.isSuccess) return resolved
            lastFailure = resolved
        }

        return lastFailure ?: failure(
            ProviderStatus.NO_STREAM,
            "Atodo returned no playable stream",
        )
    }

    private suspend fun resolveSource(
        item: MediaItem,
        source: SourceOption,
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        val sourcePayload = mediaRepository.source(item, source.id)
        val rawTranslations = collection(
            sourcePayload["translations"],
            listOf("translation_id", "id"),
        )
        if (rawTranslations.isEmpty()) {
            return failure(
                ProviderStatus.NO_STREAM,
                "Atodo source ${source.id} returned no translations",
            )
        }

        val selectedTranslation = selectTranslation(rawTranslations, request)
        val selectedTranslationIndex = rawTranslations.indexOf(selectedTranslation)
        val translationObject = selectedTranslation.second
        val translations = rawTranslations.mapIndexed { index, entry ->
            entry.second.toProviderTranslation(index, entry.first)
        }
        val translation = translations[selectedTranslationIndex]

        val rawSeasons = collection(
            translationObject["seasons"],
            listOf("season_number", "season", "number", "id"),
        )
        val selectedSeason = rawSeasons.select(request.season, ::seasonMatches)
        val season = selectedSeason?.let { (key, value) -> value.toProviderSeason(key) }

        val rawEpisodes = collection(
            selectedSeason?.second?.get("episodes") ?: translationObject["episodes"],
            listOf("episode_number", "episode", "number", "id"),
        )
        val selectedEpisode = rawEpisodes.select(request.episode, ::episodeMatches)
        val episode = selectedEpisode?.let { (key, value) -> value.toProviderEpisode(key) }

        val streamContainer = selectedEpisode?.second
            ?: selectedSeason?.second
            ?: translationObject
        var streams = providerStreams(streamContainer["streams"] ?: streamContainer)
        if (streams.isEmpty()) {
            val data = streamContainer["data"] as? JsonObject
            if (data != null && data.isNotEmpty()) {
                val resolvedPayload = mediaRepository.resolve(source.id, data)
                streams = providerStreams(resolvedPayload["streams"] ?: resolvedPayload)
            }
        }
        val stream = streams.preferred(request.preferredQuality)
            ?: return failure(
                ProviderStatus.NO_STREAM,
                "Atodo source ${source.id} returned no playable stream",
            )

        val providerMedia = ProviderMedia(
            providerId = id,
            providerMediaId = item.id,
            mediaType = identity.mediaType,
            title = item.title,
            originalTitle = item.originalTitle.takeIf(String::isNotBlank),
            year = item.year.takeIf(String::isNotBlank),
            translations = translations,
        )
        return ProviderResult.success(
            providerId = id,
            stream = stream,
            sourceId = source.id,
            media = providerMedia,
            translation = translation,
            season = season,
            episode = episode,
        )
    }

    private fun selectTranslation(
        translations: List<Pair<String, JsonObject>>,
        request: PlaybackRequest,
    ): Pair<String, JsonObject> {
        val requestedId = request.translationId?.trim().orEmpty()
        if (requestedId.isNotEmpty()) {
            translations.firstOrNull { (key, value) ->
                requestedId == key || requestedId == value.text("translation_id", "id")
            }?.let { return it }
        }

        val requestedName = request.translationName?.trim().orEmpty()
        if (requestedName.isNotEmpty()) {
            translations.withIndex().firstOrNull { (index, entry) ->
                translationDisplayName(entry.second, index).equals(requestedName, ignoreCase = true)
            }?.let { return it.value }
        }
        return translations.first()
    }

    private fun JsonObject.toProviderTranslation(
        index: Int,
        collectionKey: String,
    ): ProviderTranslation {
        val translationId = text("translation_id", "id").ifBlank {
            collectionKey.takeIf(String::isNotBlank).orEmpty()
        }
        val seasons = collection(
            this["seasons"],
            listOf("season_number", "season", "number", "id"),
        ).map { (key, value) -> value.toProviderSeason(key) }
        return ProviderTranslation(
            id = translationId.takeIf(String::isNotBlank),
            name = translationDisplayName(this, index),
            language = text("language", "lang", "language_code", "audio_language")
                .takeIf(String::isNotBlank),
            isOriginal = text("original", "is_original").equals("true", ignoreCase = true),
            seasons = seasons,
            streams = providerStreams(this["streams"] ?: this),
        )
    }

    private fun JsonObject.toProviderSeason(collectionKey: String): ProviderSeason {
        val number = text("season_number", "season", "number").ifBlank { collectionKey }
        val episodes = collection(
            this["episodes"],
            listOf("episode_number", "episode", "number", "id"),
        ).map { (key, value) -> value.toProviderEpisode(key) }
        return ProviderSeason(
            id = text("id", "season_id").takeIf(String::isNotBlank),
            number = number,
            name = text("name", "title", "label").takeIf(String::isNotBlank),
            episodes = episodes,
        )
    }

    private fun JsonObject.toProviderEpisode(collectionKey: String): ProviderEpisode {
        val number = text("episode_number", "episode", "number").ifBlank { collectionKey }
        return ProviderEpisode(
            id = text("id", "episode_id").takeIf(String::isNotBlank),
            number = number,
            name = text("name", "title", "label").takeIf(String::isNotBlank),
            streams = providerStreams(this["streams"] ?: this),
        )
    }

    private fun providerStreams(element: JsonElement): List<ProviderStream> =
        streamUrls(element).map { url ->
            ProviderStream(
                url = url,
                type = url.toStreamType(),
                quality = url.qualityOrNull(),
            )
        }

    private fun List<ProviderStream>.preferred(quality: String?): ProviderStream? {
        val requested = quality?.trim().orEmpty()
        if (requested.isNotEmpty()) {
            firstOrNull {
                it.quality?.label.equals(requested, ignoreCase = true) ||
                    it.url.contains(requested, ignoreCase = true)
            }?.let { return it }
        }
        return firstOrNull()
    }

    private fun httpFailure(error: ApiHttpException): ProviderResult = failure(
        status = when {
            error.statusCode == 404 -> ProviderStatus.NOT_FOUND
            error.statusCode >= 500 -> ProviderStatus.SERVER_ERROR
            error.statusCode in 400..499 -> ProviderStatus.INVALID_REQUEST
            else -> ProviderStatus.SERVER_ERROR
        },
        message = error.message,
        cause = error,
    )

    private fun failure(
        status: ProviderStatus,
        message: String?,
        cause: Throwable? = null,
    ): ProviderResult = ProviderResult.failure(
        providerId = id,
        status = status,
        message = message,
        cause = cause,
    )

    private fun MediaType.toAtodoType(): String = when (this) {
        MediaType.MOVIE -> "movie"
        MediaType.TV -> "tv"
    }

    private fun seasonMatches(key: String, value: JsonObject, requested: String): Boolean =
        requested == key || requested == value.text("season_number", "season", "number", "id") ||
            requested.equals(value.text("name", "title", "label"), ignoreCase = true)

    private fun episodeMatches(key: String, value: JsonObject, requested: String): Boolean =
        requested == key || requested == value.text("episode_number", "episode", "number", "id") ||
            requested.equals(value.text("name", "title", "label"), ignoreCase = true)

    private fun String.toStreamType(): ProviderStreamType = when {
        contains(".m3u8", ignoreCase = true) -> ProviderStreamType.HLS
        contains(".mp4", ignoreCase = true) -> ProviderStreamType.MP4
        contains(".mpd", ignoreCase = true) -> ProviderStreamType.DASH
        else -> ProviderStreamType.UNKNOWN
    }

    private fun String.qualityOrNull(): ProviderQuality? {
        val match = QUALITY_PATTERN.find(this) ?: return null
        val height = match.groupValues[1].toIntOrNull() ?: return null
        return ProviderQuality(label = "${height}p", height = height)
    }

    private fun <T> List<T>.prefer(requested: String?, key: (T) -> String): List<T> {
        val preferred = requested?.trim().orEmpty()
        if (preferred.isEmpty()) return this
        val selected = firstOrNull { key(it) == preferred } ?: return this
        return listOf(selected) + filterNot { it === selected }
    }

    private fun List<Pair<String, JsonObject>>.select(
        requested: String?,
        matches: (String, JsonObject, String) -> Boolean,
    ): Pair<String, JsonObject>? {
        if (isEmpty()) return null
        val preferred = requested?.trim().orEmpty()
        return if (preferred.isEmpty()) first() else firstOrNull {
            matches(it.first, it.second, preferred)
        } ?: first()
    }

    private companion object {
        const val ID = "atodo"
        val QUALITY_PATTERN = Regex("(?<!\\d)(2160|1440|1080|720|576|480|360|240)p?(?!\\d)")
    }
}
