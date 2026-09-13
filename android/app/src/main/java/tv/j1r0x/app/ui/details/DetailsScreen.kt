package tv.j1r0x.app.ui.details

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import kotlinx.serialization.json.JsonObject
import tv.j1r0x.app.domain.model.SourceOption
import tv.j1r0x.app.ui.DetailsState
import tv.j1r0x.app.ui.common.FavoriteButton
import tv.j1r0x.app.ui.common.RetryButton
import tv.j1r0x.app.ui.common.WatchButton
import tv.j1r0x.app.utils.isTechnicalValue
import tv.j1r0x.app.utils.text
import tv.j1r0x.app.utils.translationDisplayName
import tv.j1r0x.app.utils.translationStableKey

private val SelectorBackground = Color(0xFF19191E)
private val SelectorBorder = Color(0xFF686872)
private val SelectedRed = Color(0xFFE50914)

@Composable
fun DetailsScreen(
    state: DetailsState,
    isFavorite: Boolean,
    onBack: () -> Unit,
    onWatch: () -> Unit,
    onSource: (String) -> Unit,
    onTranslation: (JsonObject, Int) -> Unit,
    onSeason: (JsonObject) -> Unit,
    onEpisode: (JsonObject) -> Unit,
    onFavorite: () -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        ) {
            TextButton(onClick = onBack) { Text("← Назад") }
            state.item?.let { item ->
                Row {
                    AsyncImage(
                        item.poster,
                        item.title,
                        Modifier.widthIn(max = 260.dp).fillMaxWidth(.3f).aspectRatio(2f / 3f),
                        contentScale = ContentScale.Crop,
                    )
                    Column(Modifier.padding(18.dp)) {
                        Text(item.title, style = MaterialTheme.typography.headlineMedium)
                        Text(item.originalTitle, color = Color.Gray)
                        Text("${item.year}  ★ ${item.rating}", color = Color.LightGray)
                        Spacer(Modifier.height(12.dp))
                        Text(item.overview.ifBlank { "Описание отсутствует." })
                        Row {
                            WatchButton(onClick = onWatch)
                            Spacer(Modifier.width(8.dp))
                            FavoriteButton(isFavorite = isFavorite, onClick = onFavorite)
                        }
                    }
                }
            }
            if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error)
                RetryButton(onClick = onWatch)
            }

            SelectableRow(
                title = "Источник",
                values = state.sources,
                selectedKey = state.selectedSourceId,
                key = { source, _ -> source.id },
                label = { source, index -> sourceDisplayName(source, index) },
                onSelect = { source, _ -> onSource(source.id) },
            )
            SelectableRow(
                title = "Озвучка",
                values = state.translations,
                selectedKey = state.selectedTranslationKey,
                key = { value, index -> translationStableKey(value.second, index) },
                label = { value, index -> translationDisplayName(value.second, index) },
                onSelect = { value, index -> onTranslation(value.second, index) },
            )
            SelectableRow(
                title = "Сезон",
                values = state.seasons,
                selectedKey = state.seasons.firstOrNull { it.second == state.season }?.first.orEmpty(),
                key = { value, _ -> value.first },
                label = { value, _ -> "Сезон ${value.first}" },
                onSelect = { value, _ -> onSeason(value.second) },
            )
            SelectableRow(
                title = "Серия",
                values = state.episodes,
                selectedKey = state.episodes.firstOrNull { it.second == state.episode }?.first.orEmpty(),
                key = { value, _ -> value.first },
                label = { value, _ ->
                    value.second.text("episode_name", "name", "title")
                        .ifBlank { "Серия ${value.first}" }
                },
                onSelect = { value, _ -> onEpisode(value.second) },
            )
        }
    }
}

private fun sourceDisplayName(source: SourceOption, index: Int): String {
    val value = source.name.trim()
    return if (value.isBlank() || isTechnicalValue(value, source.id)) {
        "Источник №${index + 1}"
    } else {
        value
    }
}

@Composable
private fun <T> SelectableRow(
    title: String,
    values: List<T>,
    selectedKey: String,
    key: (T, Int) -> String,
    label: (T, Int) -> String,
    onSelect: (T, Int) -> Unit,
) {
    if (values.isEmpty()) return
    Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp))
    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        itemsIndexed(values, key = { index, value -> key(value, index) }) { index, value ->
            val itemKey = key(value, index)
            SelectableButton(
                text = label(value, index),
                selected = selectedKey.isNotBlank() && selectedKey == itemKey,
                onClick = { onSelect(value, index) },
            )
        }
    }
}

@Composable
private fun SelectableButton(text: String, selected: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) 1.04f else 1f, label = "selectorFocus")
    val borderColor = when {
        focused -> Color.White
        selected -> SelectedRed
        else -> SelectorBorder
    }
    Button(
        onClick = onClick,
        modifier = Modifier
            .widthIn(min = 112.dp, max = 280.dp)
            .heightIn(min = 52.dp)
            .scale(scale)
            .onFocusChanged { focused = it.isFocused },
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(if (focused) 2.dp else 1.dp, borderColor),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (selected) SelectedRed else SelectorBackground,
            contentColor = Color.White,
        ),
        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
    ) {
        Text(
            text = if (selected) "✓ $text" else text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
