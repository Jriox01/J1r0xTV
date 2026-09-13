package tv.j1r0x.app.data.provider.rezka

import tv.j1r0x.app.data.provider.MediaType
import tv.j1r0x.app.data.provider.ProviderEpisode
import tv.j1r0x.app.data.provider.ProviderMedia
import tv.j1r0x.app.data.provider.ProviderQuality
import tv.j1r0x.app.data.provider.ProviderSeason
import tv.j1r0x.app.data.provider.ProviderStream
import tv.j1r0x.app.data.provider.ProviderStreamType
import tv.j1r0x.app.data.provider.ProviderTranslation
import tv.j1r0x.app.utils.isTechnicalValue

object RezkaMapper {
    const val PROVIDER_ID = "rezka"

    fun toProviderMedia(media: RezkaMediaResult): ProviderMedia = ProviderMedia(
        providerId = PROVIDER_ID,
        providerMediaId = media.id,
        mediaType = when (media.mediaType) {
            RezkaMediaType.MOVIE -> MediaType.MOVIE
            RezkaMediaType.TV -> MediaType.TV
        },
        title = media.title,
        originalTitle = media.originalTitle,
        year = media.year,
        translations = media.translations.mapIndexed(::toProviderTranslation),
    )

    fun toProviderTranslation(index: Int, translation: RezkaTranslation): ProviderTranslation =
        ProviderTranslation(
            id = translation.id,
            name = translationDisplayName(translation, index),
            language = translation.language
                ?.trim()
                ?.takeIf { it.isNotEmpty() && !isTechnicalValue(it, translation.id.orEmpty()) },
            isOriginal = translation.isOriginal,
            seasons = translation.seasons.map(::toProviderSeason),
            streams = translation.streams.mapNotNull(::toProviderStream),
        )

    fun toProviderSeason(season: RezkaSeason): ProviderSeason = ProviderSeason(
        id = season.id,
        number = season.number,
        name = season.name,
        episodes = season.episodes.map(::toProviderEpisode),
    )

    fun toProviderEpisode(episode: RezkaEpisode): ProviderEpisode = ProviderEpisode(
        id = episode.id,
        number = episode.number,
        name = episode.name,
        streams = episode.streams.mapNotNull(::toProviderStream),
    )

    fun toProviderStream(stream: RezkaStream): ProviderStream? {
        val url = stream.url.trim()
        if (url.isEmpty()) return null
        return ProviderStream(
            url = url,
            type = when (stream.type) {
                RezkaStreamType.HLS -> ProviderStreamType.HLS
                RezkaStreamType.MP4 -> ProviderStreamType.MP4
                RezkaStreamType.DASH -> ProviderStreamType.DASH
                RezkaStreamType.UNKNOWN -> ProviderStreamType.UNKNOWN
            },
            quality = stream.quality?.let(::toProviderQuality),
            mimeType = stream.mimeType,
            headers = stream.headers,
        )
    }

    fun toProviderQuality(quality: RezkaQuality): ProviderQuality = ProviderQuality(
        id = quality.id,
        label = quality.label,
        height = quality.height,
        bitrate = quality.bitrate,
    )

    fun translationDisplayName(translation: RezkaTranslation, index: Int): String {
        val id = translation.id.orEmpty()
        val name = translation.name
            ?.trim()
            ?.takeIf { it.isNotEmpty() && !isTechnicalValue(it, id) }
            ?: return "Озвучка №${index + 1}"
        val language = translation.language
            ?.trim()
            ?.uppercase()
            ?.takeIf { it.isNotEmpty() && !isTechnicalValue(it, id) }
        return if (language != null && !name.contains(language, ignoreCase = true)) {
            "$name • $language"
        } else {
            name
        }
    }
}
