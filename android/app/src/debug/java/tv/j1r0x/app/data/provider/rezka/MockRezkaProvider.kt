package tv.j1r0x.app.data.provider.rezka

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

enum class MockRezkaMode {
    SUCCESS_MOVIE,
    SUCCESS_SERIES,
    NOT_FOUND,
    NETWORK_ERROR,
    SERVER_ERROR,
    NO_STREAM,
}

/** Mutable debug-only switch for the provider diagnostics screen and tests. */
class MockRezkaController(
    enabled: Boolean = false,
    mode: MockRezkaMode = MockRezkaMode.NO_STREAM,
) {
    @Volatile
    var enabled: Boolean = enabled

    @Volatile
    var mode: MockRezkaMode = mode
}

/** Shared controller used by the debug build. It is intentionally off at startup. */
val debugRezkaController = MockRezkaController()

/**
 * Debug-only deterministic Rezka substitute. No Rezka host is contacted.
 * The single test stream is Apple's public HLS authoring example.
 */
class MockRezkaProvider(
    private val controller: MockRezkaController = debugRezkaController,
) : VideoProvider {
    override val id: String = RezkaMapper.PROVIDER_ID
    override val displayName: String = "Rezka (Mock)"
    override val priority: Int = RezkaConfig.DEFAULT_PRIORITY
    override val enabled: Boolean
        get() = controller.enabled

    override suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        if (!enabled) {
            return ProviderResult.failure(id, ProviderStatus.DISABLED, "Rezka mock is disabled")
        }
        return when (controller.mode) {
            MockRezkaMode.SUCCESS_MOVIE -> movieSuccess(identity, request)
            MockRezkaMode.SUCCESS_SERIES -> seriesSuccess(identity, request)
            MockRezkaMode.NOT_FOUND -> failure(ProviderStatus.NOT_FOUND, "Mock content not found")
            MockRezkaMode.NETWORK_ERROR -> failure(ProviderStatus.NETWORK_ERROR, "Mock network error")
            MockRezkaMode.SERVER_ERROR -> failure(ProviderStatus.SERVER_ERROR, "Mock server error")
            MockRezkaMode.NO_STREAM -> failure(ProviderStatus.NO_STREAM, "Mock stream is unavailable")
        }
    }

    private fun movieSuccess(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        val stream = testStream(request.preferredQuality)
        val translation = ProviderTranslation(
            id = request.translationId ?: "mock-translation-original",
            name = request.translationName ?: "Тестовая озвучка",
            language = "RU",
            streams = listOf(stream),
        )
        val media = ProviderMedia(
            providerId = id,
            providerMediaId = request.providerMediaId ?: "mock-movie",
            mediaType = MediaType.MOVIE,
            title = identity.title,
            originalTitle = identity.originalTitle,
            year = identity.year,
            translations = listOf(translation),
        )
        return ProviderResult.success(
            providerId = id,
            stream = stream,
            media = media,
            translation = translation,
        )
    }

    private fun seriesSuccess(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        val stream = testStream(request.preferredQuality)
        val episode = ProviderEpisode(
            id = "mock-episode",
            number = request.episode ?: "1",
            name = "Тестовая серия",
            streams = listOf(stream),
        )
        val season = ProviderSeason(
            id = "mock-season",
            number = request.season ?: "1",
            name = "Сезон ${request.season ?: "1"}",
            episodes = listOf(episode),
        )
        val translation = ProviderTranslation(
            id = request.translationId ?: "mock-translation-original",
            name = request.translationName ?: "Тестовая озвучка",
            language = "RU",
            seasons = listOf(season),
        )
        val media = ProviderMedia(
            providerId = id,
            providerMediaId = request.providerMediaId ?: "mock-series",
            mediaType = MediaType.TV,
            title = identity.title,
            originalTitle = identity.originalTitle,
            year = identity.year,
            translations = listOf(translation),
        )
        return ProviderResult.success(
            providerId = id,
            stream = stream,
            media = media,
            translation = translation,
            season = season,
            episode = episode,
        )
    }

    private fun failure(status: ProviderStatus, message: String): ProviderResult =
        ProviderResult.failure(providerId = id, status = status, message = message)

    private fun testStream(preferredQuality: String?): ProviderStream = ProviderStream(
        url = APPLE_PUBLIC_HLS_TEST_URL,
        type = ProviderStreamType.HLS,
        quality = ProviderQuality(label = preferredQuality ?: "Test HLS"),
        mimeType = "application/x-mpegURL",
    )

    private companion object {
        const val APPLE_PUBLIC_HLS_TEST_URL =
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
    }
}
