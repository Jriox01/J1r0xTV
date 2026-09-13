package tv.j1r0x.app.domain.model

import kotlinx.serialization.json.JsonObject

data class MediaItem(
    val id: String, val type: String, val title: String,
    val originalTitle: String = "", val overview: String = "",
    val poster: String = "", val backdrop: String = "",
    val year: String = "", val rating: String = "",
    val raw: JsonObject = JsonObject(emptyMap()),
    val canonicalInfo: Map<String, String> = emptyMap()
)
data class SourceOption(val id: String, val name: String)
data class PlaybackSelection(
    val item: MediaItem, val sourceId: String, val translationName: String = "",
    val season: String = "", val episode: String = "", val streamUrl: String,
    val resumePositionMs: Long = 0,
    val providerId: String = "atodo",
    val providerMediaId: String = item.id,
    val translationId: String = "",
    val attemptedProviderIds: Set<String> = setOf(providerId),
    val fallbackAttempted: Boolean = false,
    val streamHeaders: Map<String, String> = emptyMap(),
)
sealed interface UiState<out T> {
    data object Loading : UiState<Nothing>
    data class Content<T>(val value: T) : UiState<T>
    data class Error(val message: String) : UiState<Nothing>
    data object Empty : UiState<Nothing>
}
