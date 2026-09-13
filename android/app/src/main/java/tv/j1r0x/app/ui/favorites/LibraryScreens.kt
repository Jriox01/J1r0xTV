package tv.j1r0x.app.ui.favorites

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import tv.j1r0x.app.data.database.FavoriteEntity
import tv.j1r0x.app.data.database.WatchHistoryEntity
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.ui.home.MediaCard
import tv.j1r0x.app.ui.toMedia

@Composable fun FavoritesScreen(values:List<FavoriteEntity>,onOpen:(MediaItem)->Unit,onToggle:(MediaItem)->Unit){if(values.isEmpty())Box(Modifier.fillMaxSize()){Text("Избранное пусто",Modifier.padding(24.dp))}else LazyColumn(contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){items(values,key={it.mediaId+it.mediaType}){value->Box(Modifier.width(180.dp)){MediaCard(value.toMedia(),onOpen,onToggle)}}}}
@Composable fun HistoryScreen(values:List<WatchHistoryEntity>,onContinue:(WatchHistoryEntity)->Unit,onClear:()->Unit){Column(Modifier.fillMaxSize().padding(16.dp)){Button(onClick=onClear,enabled=values.isNotEmpty()){Text("Очистить историю")};if(values.isEmpty())Text("История пуста",Modifier.padding(top=20.dp))else LazyColumn(verticalArrangement=Arrangement.spacedBy(10.dp)){items(values,key={it.mediaId+it.mediaType+it.season+it.episode}){v->Card{Column(Modifier.fillMaxWidth().padding(12.dp)){Text(v.title);if(v.episode.isNotBlank())Text("Сезон ${v.season}, серия ${v.episode}");LinearProgressIndicator(progress={v.progress.toFloat()},Modifier.fillMaxWidth());TextButton(onClick={onContinue(v)}){Text("Продолжить")}}}}}}}
