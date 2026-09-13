package tv.j1r0x.app.ui

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import tv.j1r0x.app.BuildConfig
import tv.j1r0x.app.J1r0xApplication
import tv.j1r0x.app.data.database.FavoriteEntity
import tv.j1r0x.app.data.database.WatchHistoryEntity
import tv.j1r0x.app.data.provider.PlaybackRequest
import tv.j1r0x.app.data.provider.ProviderDiagnostic
import tv.j1r0x.app.data.provider.ProviderStatus
import tv.j1r0x.app.data.provider.toMediaIdentity
import tv.j1r0x.app.data.provider.toPlaybackRequest
import tv.j1r0x.app.data.provider.toPlaybackSelection
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.domain.model.PlaybackSelection
import tv.j1r0x.app.domain.model.SourceOption
import tv.j1r0x.app.domain.model.UiState
import tv.j1r0x.app.utils.appJson
import tv.j1r0x.app.utils.collection
import tv.j1r0x.app.utils.isTechnicalValue
import tv.j1r0x.app.utils.parseMedia
import tv.j1r0x.app.utils.streamUrls
import tv.j1r0x.app.utils.text
import tv.j1r0x.app.utils.translationDisplayName
import tv.j1r0x.app.utils.translationStableKey

data class SplashState(
    val status: String = "Инициализация...",
    val ready: Boolean = false,
    val warning: String? = null,
)

data class DetailsState(
    val item: MediaItem? = null,
    val loading: Boolean = false,
    val error: String? = null,
    val sources: List<SourceOption> = emptyList(),
    val selectedSourceId: String = "",
    val translations: List<Pair<String, JsonObject>> = emptyList(),
    val translation: JsonObject? = null,
    val selectedTranslationKey: String = "",
    val selectedTranslationName: String = "",
    val seasons: List<Pair<String, JsonObject>> = emptyList(),
    val season: JsonObject? = null,
    val episodes: List<Pair<String, JsonObject>> = emptyList(),
    val episode: JsonObject? = null,
)

data class RezkaConfigurationSummary(
    val enabled: Boolean,
    val baseUrlConfigured: Boolean,
    val apiKeyConfigured: Boolean,
)

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val container = app as J1r0xApplication
    private val media = container.media
    private val library = container.library
    private val providerManager = container.providerManager
    private val startedPlaybackKeys = mutableSetOf<String>()
    private var playbackFallbackInProgress = false

    val splash = MutableStateFlow(SplashState())
    val catalog = MutableStateFlow<UiState<List<MediaItem>>>(UiState.Loading)
    val details = MutableStateFlow(DetailsState())
    val playback = MutableStateFlow<PlaybackSelection?>(null)
    val playbackStatus = MutableStateFlow<String?>(null)
    val favorites = library.favorites.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList(),
    )
    val history = library.history.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList(),
    )

    init {
        initialize()
    }

    private fun initialize() = viewModelScope.launch {
        splash.value = SplashState("Загрузка настроек...")
        runCatching { container.settings.lastSection.first() }
        splash.value = SplashState("Подготовка базы...")
        runCatching { container.database.openHelper.writableDatabase }
        splash.value = SplashState("Подключение к серверу...")
        loadCatalog("movie", true)
    }

    fun loadCatalog(type: String, initial: Boolean = false) = viewModelScope.launch {
        catalog.value = UiState.Loading
        if (initial) splash.value = SplashState("Загрузка каталога...")
        val result = runCatching { media.catalog(type) }
        catalog.value = result.fold(
            { if (it.isEmpty()) UiState.Empty else UiState.Content(it) },
            { UiState.Error(it.message ?: "Ошибка сети") },
        )
        container.settings.setLastSection(if (type == "tv") "series" else "movies")
        if (initial) {
            splash.value = SplashState(
                "Готово",
                true,
                result.exceptionOrNull()?.let { "Нет соединения. Можно повторить загрузку." },
            )
        }
    }

    fun search(query: String) = viewModelScope.launch {
        if (query.isBlank()) return@launch
        catalog.value = UiState.Loading
        val result = runCatching { media.search(query) }
        catalog.value = result.fold(
            { if (it.isEmpty()) UiState.Empty else UiState.Content(it) },
            { UiState.Error(it.message ?: "Ошибка поиска") },
        )
    }

    fun open(item: MediaItem) = viewModelScope.launch {
        details.value = DetailsState(loading = true)
        val result = runCatching { media.details(item.type, item.id) }
        details.value = result.fold(
            { DetailsState(item = it) },
            { DetailsState(error = it.message) },
        )
    }

    fun loadSources() = viewModelScope.launch {
        val item = details.value.item ?: return@launch
        val startedAt = System.currentTimeMillis()
        details.value = details.value.copy(
            loading = true,
            error = null,
            selectedSourceId = "",
            translations = emptyList(),
            translation = null,
            selectedTranslationKey = "",
            selectedTranslationName = "",
            seasons = emptyList(),
            season = null,
            episodes = emptyList(),
            episode = null,
        )
        val result = runCatching { media.sources(item) }
        result.onSuccess { (full, sources) ->
            providerManager.registerStatus(
                ATODO_PROVIDER_ID,
                if (sources.isEmpty()) ProviderStatus.NO_STREAM else ProviderStatus.SUCCESS,
                System.currentTimeMillis() - startedAt,
            )
            details.value = details.value.copy(
                item = full,
                loading = false,
                sources = sources,
                error = if (sources.isEmpty()) "Источники не найдены" else null,
            )
        }.onFailure { error ->
            providerManager.registerStatus(
                ATODO_PROVIDER_ID,
                ProviderStatus.SERVER_ERROR,
                System.currentTimeMillis() - startedAt,
            )
            val resolved = resolveBackup(
                item = item,
                request = PlaybackRequest(providerMediaId = item.id),
                attemptedProviderIds = setOf(ATODO_PROVIDER_ID),
            )
            if (!resolved) {
                if (BuildConfig.DEBUG) Log.w("J1r0xProvider", "Atodo source/list failed", error)
                details.value = details.value.copy(
                    loading = false,
                    error = "Рабочий источник не найден.",
                )
            }
        }
    }

    fun selectSource(id: String) = viewModelScope.launch {
        val item = details.value.item ?: return@launch
        val startedAt = System.currentTimeMillis()
        val available = details.value.sources
        val requested = available.firstOrNull { it.id == id }
        val ordered = listOfNotNull(requested) + available.filterNot { it.id == id }
        var lastError: Throwable? = null
        for (source in ordered) {
            details.value = details.value.copy(
                loading = true,
                selectedSourceId = source.id,
                error = null,
                translations = emptyList(),
                translation = null,
                selectedTranslationKey = "",
                selectedTranslationName = "",
                seasons = emptyList(),
                season = null,
                episodes = emptyList(),
                episode = null,
            )
            val result = runCatching { media.source(item, source.id) }
            if (result.isFailure) {
                lastError = result.exceptionOrNull()
                if (BuildConfig.DEBUG) {
                    Log.w("J1r0xTV", "source=${source.id} unavailable; trying next", lastError)
                }
                continue
            }
            val data = result.getOrThrow()
            val translations = collection(data["translations"], listOf("id", "translation_id"))
            if (translations.isEmpty()) {
                lastError = IllegalStateException("Источник не вернул список озвучек")
                if (BuildConfig.DEBUG) {
                    Log.w("J1r0xTV", "source=${source.id} translations=0; trying next")
                }
                continue
            }
            if (BuildConfig.DEBUG) Log.d("J1r0xTV", "translation=${translations.first().second}")
            providerManager.registerStatus(
                ATODO_PROVIDER_ID,
                ProviderStatus.SUCCESS,
                System.currentTimeMillis() - startedAt,
            )
            details.value = details.value.copy(
                loading = false,
                translations = translations,
                error = null,
            )
            return@launch
        }

        val resolved = resolveBackup(
            item = item,
            request = PlaybackRequest(providerMediaId = item.id, sourceId = id),
            attemptedProviderIds = setOf(ATODO_PROVIDER_ID),
        )
        if (!resolved) {
            details.value = details.value.copy(
                loading = false,
                error = "Рабочий источник не найден.",
            )
        }
        providerManager.registerStatus(
            ATODO_PROVIDER_ID,
            ProviderStatus.NO_STREAM,
            System.currentTimeMillis() - startedAt,
        )
        if (BuildConfig.DEBUG && lastError != null) {
            Log.w("J1r0xTV", "all Atodo sources unavailable", lastError)
        }
    }

    fun selectTranslation(value: JsonObject, index: Int) {
        val displayName = translationDisplayName(value, index)
        if (BuildConfig.DEBUG) Log.d("J1r0xTV", "translationDisplayName=$displayName")
        val seasons = collection(
            value["seasons"],
            listOf("season_number", "season", "number", "id"),
        )
        details.value = details.value.copy(
            translation = value,
            selectedTranslationKey = translationStableKey(value, index),
            selectedTranslationName = displayName,
            seasons = seasons,
            season = null,
            episodes = emptyList(),
            episode = null,
        )
        if (seasons.isEmpty()) playContainer(value)
    }

    fun selectSeason(value: JsonObject) {
        val episodes = collection(
            value["episodes"],
            listOf("episode_number", "episode", "number", "id"),
        )
        details.value = details.value.copy(
            season = value,
            episodes = episodes,
            episode = null,
        )
    }

    fun selectEpisode(value: JsonObject) {
        details.value = details.value.copy(episode = value)
        playContainer(value)
    }

    private fun playContainer(value: JsonObject) = viewModelScope.launch {
        val state = details.value
        val item = state.item ?: return@launch
        val startedAt = System.currentTimeMillis()
        details.value = state.copy(loading = true, error = null)
        val translationName = state.selectedTranslationName.ifBlank {
            state.translation?.let { translationDisplayName(it, 0) }.orEmpty()
        }
        val translationId = state.selectedTranslationKey.ifBlank {
            state.translation?.text("translation_id", "id").orEmpty()
        }
        val season = state.season?.text("season_number", "season", "number", "id").orEmpty()
        val episode = state.episode?.text("episode_number", "episode", "number", "id").orEmpty()
        val request = PlaybackRequest(
            providerMediaId = item.id,
            sourceId = state.selectedSourceId.takeIf { it.isNotBlank() },
            translationId = translationId.takeIf { it.isNotBlank() },
            translationName = translationName.takeIf { it.isNotBlank() },
            season = season.takeIf { it.isNotBlank() },
            episode = episode.takeIf { it.isNotBlank() },
        )

        val direct = streamUrls(value["streams"] ?: value)
        val result = runCatching {
            direct.firstOrNull() ?: run {
                val data = value["data"] as? JsonObject
                    ?: error("Прямой поток или episode.data отсутствует")
                streamUrls(
                    media.resolve(state.selectedSourceId, data)["streams"]
                        ?: JsonObject(emptyMap()),
                ).firstOrNull() ?: error("Источник не вернул видеопоток")
            }
        }
        result.onSuccess { url ->
            providerManager.registerStatus(
                ATODO_PROVIDER_ID,
                ProviderStatus.SUCCESS,
                System.currentTimeMillis() - startedAt,
            )
            playbackStatus.value = null
            playback.value = PlaybackSelection(
                item = item,
                sourceId = state.selectedSourceId,
                translationName = translationName,
                season = season,
                episode = episode,
                streamUrl = url,
                providerId = ATODO_PROVIDER_ID,
                providerMediaId = item.id,
                translationId = translationId,
                attemptedProviderIds = setOf(ATODO_PROVIDER_ID),
            )
            details.value = details.value.copy(loading = false)
        }.onFailure { error ->
            providerManager.registerStatus(
                ATODO_PROVIDER_ID,
                ProviderStatus.NO_STREAM,
                System.currentTimeMillis() - startedAt,
            )
            if (BuildConfig.DEBUG) Log.w("J1r0xProvider", "Atodo stream resolution failed", error)
            val resolved = resolveBackup(
                item = item,
                request = request,
                attemptedProviderIds = setOf(ATODO_PROVIDER_ID),
            )
            if (!resolved) {
                playbackStatus.value = null
                details.value = details.value.copy(
                    loading = false,
                    error = "Рабочий источник не найден.",
                )
            }
        }
    }

    private suspend fun resolveBackup(
        item: MediaItem,
        request: PlaybackRequest,
        attemptedProviderIds: Set<String>,
    ): Boolean {
        playbackStatus.value = "Основной источник недоступен. Пробуем резервный…"
        val result = providerManager.resolve(
            identity = item.toMediaIdentity(),
            request = request,
            attemptedProviderIds = attemptedProviderIds,
        )
        val selection = result.toPlaybackSelection(item, request) ?: run {
            playbackStatus.value = null
            return false
        }
        playback.value = selection
        details.value = details.value.copy(loading = false, error = null)
        return true
    }

    fun handlePlaybackError(selection: PlaybackSelection, error: Throwable, positionMs: Long) {
        if (selection.fallbackAttempted || playbackFallbackInProgress) {
            playback.value = null
            playbackStatus.value = null
            details.value = details.value.copy(loading = false, error = "Рабочий источник не найден.")
            return
        }
        playbackFallbackInProgress = true
        playbackStatus.value = "Основной источник не запустился. Пробуем резервный…"
        providerManager.registerStatus(selection.providerId, ProviderStatus.PLAYBACK_ERROR)
        if (BuildConfig.DEBUG) {
            Log.w(
                "J1r0xProvider",
                "provider=${selection.providerId} status=PLAYBACK_ERROR error=${error.javaClass.simpleName}",
            )
        }
        viewModelScope.launch {
            try {
                val request = selection.toPlaybackRequest().copy(resumePositionMs = positionMs)
                val result = providerManager.resolveAfterPlaybackError(
                    identity = selection.item.toMediaIdentity(),
                    request = request,
                    failedProviderId = selection.providerId,
                    attemptedProviderIds = selection.attemptedProviderIds,
                )
                val fallback = result.toPlaybackSelection(
                    item = selection.item,
                    request = request,
                    fallbackAttempted = true,
                )
                if (fallback != null) {
                    playback.value = fallback
                } else {
                    playback.value = null
                    playbackStatus.value = null
                    details.value = details.value.copy(
                        loading = false,
                        error = "Рабочий источник не найден.",
                    )
                }
            } finally {
                playbackFallbackInProgress = false
            }
        }
    }

    fun recordPlaybackStarted(selection: PlaybackSelection) = viewModelScope.launch {
        startedPlaybackKeys += selection.historyKey()
        playbackStatus.value = null
        library.started(
            item = selection.item,
            source = selection.sourceId,
            translation = selection.translationName,
            season = selection.season,
            episode = selection.episode,
            providerId = selection.providerId,
            providerMediaId = selection.providerMediaId,
            translationId = selection.translationId,
            positionMs = selection.resumePositionMs,
        )
    }

    fun toggleFavorite(item: MediaItem, current: Boolean) = viewModelScope.launch {
        library.toggle(item, current)
    }

    fun clearHistory() = viewModelScope.launch { library.clearHistory() }

    fun continueWatching(entry: WatchHistoryEntity) = viewModelScope.launch {
        val item = entry.toMedia()
        details.value = DetailsState(item = item, loading = true)
        playbackStatus.value = "Получаем свежий поток…"
        val request = PlaybackRequest(
            providerMediaId = entry.providerMediaId.ifBlank { entry.mediaId },
            sourceId = entry.sourceId.takeIf { it.isNotBlank() },
            translationId = entry.translationId.takeIf { it.isNotBlank() },
            translationName = entry.translationName.takeIf { it.isNotBlank() },
            season = entry.season.takeIf { it.isNotBlank() },
            episode = entry.episode.takeIf { it.isNotBlank() },
            resumePositionMs = entry.positionMs,
        )
        val result = runCatching {
            providerManager.resolve(
                identity = item.toMediaIdentity(),
                request = request,
                preferredProviderId = entry.providerId.ifBlank { ATODO_PROVIDER_ID },
            )
        }
        result.onSuccess { providerResult ->
            val selection = providerResult.toPlaybackSelection(item, request)
            if (selection != null) {
                playback.value = selection
                details.value = DetailsState(item = item)
            } else {
                playbackStatus.value = null
                details.value = DetailsState(item = item, error = "Рабочий источник не найден.")
            }
        }.onFailure { error ->
            playbackStatus.value = null
            details.value = DetailsState(
                item = item,
                error = "Не удалось продолжить: ${error.message ?: "источник недоступен"}",
            )
        }
    }

    fun saveProgress(selection: PlaybackSelection, position: Long, duration: Long) =
        viewModelScope.launch {
            if (selection.historyKey() !in startedPlaybackKeys) return@launch
            val item = selection.item
            val entry = history.value.firstOrNull {
                it.mediaId == item.id &&
                    it.mediaType == item.type &&
                    it.season == selection.season &&
                    it.episode == selection.episode
            } ?: WatchHistoryEntity(
                mediaId = item.id,
                mediaType = item.type,
                title = item.title,
                originalTitle = item.originalTitle,
                poster = item.poster,
                backdrop = item.backdrop,
                year = item.year,
                rating = item.rating,
                rawJson = item.raw.toString(),
                providerId = selection.providerId,
                providerMediaId = selection.providerMediaId,
                sourceId = selection.sourceId,
                translationId = selection.translationId,
                translationName = selection.translationName,
                season = selection.season,
                episode = selection.episode,
            )
            library.progress(entry, position, duration)
        }

    fun closePlayer() {
        playback.value = null
        playbackStatus.value = null
    }

    fun providerDiagnostics(): List<ProviderDiagnostic> = providerManager.diagnostics()

    fun rezkaConfigurationSummary(): RezkaConfigurationSummary = RezkaConfigurationSummary(
        enabled = container.rezkaConfig.effectiveEnabled,
        baseUrlConfigured = container.rezkaConfig.baseUrl.isNotBlank(),
        apiKeyConfigured = container.rezkaConfig.isApiKeyConfigured,
    )

    fun providerHealthCheckMessage(): String =
        "Health-check не настроен: требуется документация разрешённого API."

    private fun PlaybackSelection.historyKey(): String =
        "${item.id}|${item.type}|$season|$episode"

    private companion object {
        const val ATODO_PROVIDER_ID = "atodo"
    }
}

fun FavoriteEntity.toMedia() = parseMedia(
    runCatching { appJson.parseToJsonElement(rawJson) as JsonObject }
        .getOrDefault(JsonObject(emptyMap())),
    mediaType,
).copy(
    id = mediaId,
    type = mediaType,
    title = title,
    originalTitle = originalTitle,
    poster = poster,
    backdrop = backdrop,
    year = year,
    rating = rating,
)

fun WatchHistoryEntity.toMedia() = parseMedia(
    runCatching { appJson.parseToJsonElement(rawJson) as JsonObject }
        .getOrDefault(JsonObject(emptyMap())),
    mediaType,
).copy(
    id = mediaId,
    type = mediaType,
    title = title,
    originalTitle = originalTitle,
    poster = poster,
    backdrop = backdrop,
    year = year,
    rating = rating,
)
