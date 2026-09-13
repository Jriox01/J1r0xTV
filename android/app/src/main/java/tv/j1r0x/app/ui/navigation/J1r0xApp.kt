package tv.j1r0x.app.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.ui.AppViewModel
import tv.j1r0x.app.ui.common.isTv
import tv.j1r0x.app.ui.details.DetailsScreen
import tv.j1r0x.app.ui.favorites.FavoritesScreen
import tv.j1r0x.app.ui.favorites.HistoryScreen
import tv.j1r0x.app.ui.home.CatalogScreen
import tv.j1r0x.app.ui.player.PlayerScreen
import tv.j1r0x.app.ui.providers.ProviderDiagnosticsScreen
import tv.j1r0x.app.ui.providers.providersDebugScreenEnabled
import tv.j1r0x.app.ui.splash.SplashScreen
import tv.j1r0x.app.ui.theme.J1r0xTheme

private enum class Page { MOVIES, SERIES, FAVORITES, HISTORY, SEARCH, DETAILS, PROVIDERS }

@Composable fun J1r0xApp(vm:AppViewModel) = J1r0xTheme {
    val splash by vm.splash.collectAsState()
    if(!splash.ready){ SplashScreen(splash); return@J1r0xTheme }
    val playback by vm.playback.collectAsState()
    val playbackStatus by vm.playbackStatus.collectAsState()
    if(playback!=null){
        val active=playback!!
        PlayerScreen(
            selection=active,
            statusMessage=playbackStatus,
            onStarted={vm.recordPlaybackStarted(active)},
            onProgress={position,duration->vm.saveProgress(active,position,duration)},
            onExit={position,duration->vm.saveProgress(active,position,duration);vm.closePlayer()},
            onPlaybackError={error,position->vm.handlePlaybackError(active,error,position)},
        )
        return@J1r0xTheme
    }
    val catalog by vm.catalog.collectAsState(); val details by vm.details.collectAsState()
    val favorites by vm.favorites.collectAsState(); val history by vm.history.collectAsState()
    var page by rememberSaveable { mutableStateOf(Page.MOVIES) }; var search by rememberSaveable { mutableStateOf("") }
    val favoriteKeys=remember(favorites){favorites.map{it.mediaId to it.mediaType}.toSet()}
    fun open(item:MediaItem){vm.open(item);page=Page.DETAILS}
    fun select(selected:Page){page=selected;when(selected){Page.MOVIES->vm.loadCatalog("movie");Page.SERIES->vm.loadCatalog("tv");else->{}}}
    BackHandler(page==Page.DETAILS||page==Page.PROVIDERS){page=Page.MOVIES}
    Scaffold(
        topBar={if(isTv()) NavigationBarRow(page,::select)},
        bottomBar={if(!isTv()&&page!=Page.DETAILS) NavigationBarRow(page,::select)}
    ){padding->Box(Modifier.fillMaxSize().padding(padding)){
        when(page){
            Page.MOVIES,Page.SERIES->CatalogScreen(catalog,::open,{vm.toggleFavorite(it,(it.id to it.type) in favoriteKeys)},{vm.loadCatalog(if(page==Page.SERIES)"tv" else "movie")})
            Page.FAVORITES->FavoritesScreen(favorites,::open,{vm.toggleFavorite(it,true)})
            Page.HISTORY->HistoryScreen(history,{vm.continueWatching(it)},{vm.clearHistory()})
            Page.SEARCH->Column{
                Row(Modifier.fillMaxWidth().padding(12.dp)){OutlinedTextField(search,{search=it},Modifier.weight(1f),label={Text("Поиск")},singleLine=true);IconButton(onClick={vm.search(search)}){Icon(Icons.Default.Search,"Найти")};IconButton(onClick={search=""}){Icon(Icons.Default.Clear,"Очистить")}}
                CatalogScreen(catalog,::open,{vm.toggleFavorite(it,(it.id to it.type) in favoriteKeys)},{vm.search(search)})
            }
            Page.PROVIDERS->ProviderDiagnosticsScreen(vm){page=Page.MOVIES}
            Page.DETAILS->DetailsScreen(details,details.item?.let{(it.id to it.type) in favoriteKeys}==true,{page=Page.MOVIES},{vm.loadSources()},{vm.selectSource(it)},{value,index->vm.selectTranslation(value,index)},{vm.selectSeason(it)},{vm.selectEpisode(it)},{details.item?.let{vm.toggleFavorite(it,(it.id to it.type) in favoriteKeys)}})
        }
    }}
}

@Composable private fun NavigationBarRow(page:Page,onSelect:(Page)->Unit){
    val values=buildList{add(Page.MOVIES to "Фильмы");add(Page.SERIES to "Сериалы");add(Page.FAVORITES to "Избранное");add(Page.HISTORY to "История");add(Page.SEARCH to "Поиск");if(providersDebugScreenEnabled())add(Page.PROVIDERS to "Провайдеры")}
        NavigationBar{values.forEach{(p,label)->NavigationBarItem(page==p,{onSelect(p)},{Icon(when(p){Page.MOVIES->Icons.Default.Movie;Page.SERIES->Icons.Default.Tv;Page.FAVORITES->Icons.Default.Star;Page.HISTORY->Icons.Default.History;Page.PROVIDERS->Icons.Default.Settings;else->Icons.Default.Search},label)},label={Text(label)})}}
}
