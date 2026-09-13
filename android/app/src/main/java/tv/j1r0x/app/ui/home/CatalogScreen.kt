package tv.j1r0x.app.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.*
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.*
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import tv.j1r0x.app.domain.model.*
import tv.j1r0x.app.ui.common.isTv
import tv.j1r0x.app.ui.common.RetryButton

@Composable fun CatalogScreen(state:UiState<List<MediaItem>>,onOpen:(MediaItem)->Unit,onFavorite:(MediaItem)->Unit,onRetry:()->Unit){Box(Modifier.fillMaxSize()){when(state){UiState.Loading->CircularProgressIndicator(Modifier.align(Alignment.Center));UiState.Empty->Message("Ничего не найдено",null);is UiState.Error->Message(state.message,onRetry);is UiState.Content->{val width=LocalConfiguration.current.screenWidthDp;val tv=isTv();val min=if(tv)190 else if(width>=600)170 else 135;LazyVerticalGrid(GridCells.Adaptive(min.dp),contentPadding=PaddingValues(horizontal=if(tv)40.dp else 12.dp,vertical=12.dp),horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){items(state.value,key={"${it.type}:${it.id}"}){MediaCard(it,onOpen,onFavorite)}}}}}}
@Composable private fun Message(text:String,retry:(()->Unit)?){Column(Modifier.fillMaxSize(),Arrangement.Center,Alignment.CenterHorizontally){Text(text);if(retry!=null)RetryButton(onClick=retry)}}
@Composable fun MediaCard(item:MediaItem,onOpen:(MediaItem)->Unit,onFavorite:(MediaItem)->Unit){var focused by remember{mutableStateOf(false)};val scale by animateFloatAsState(if(focused)1.06f else 1f,label="focus");Card(Modifier.scale(scale).onFocusChanged{focused=it.isFocused}.border(if(focused)2.dp else 0.dp,Color(0xFFE50914),RoundedCornerShape(8.dp)).clickable{onOpen(item)}.focusable(),colors=CardDefaults.cardColors(containerColor=Color(0xFF181818))){Box{AsyncImage(item.poster,item.title,Modifier.fillMaxWidth().aspectRatio(2f/3f),contentScale=ContentScale.Crop);IconButton(onClick={onFavorite(item)},modifier=Modifier.align(Alignment.TopEnd).background(Color.Black.copy(.55f),RoundedCornerShape(50))){Icon(Icons.Default.StarBorder,"Избранное",tint=Color.White)}};Column(Modifier.padding(8.dp)){Text(item.title,maxLines=2,overflow=TextOverflow.Ellipsis);Text(listOf(item.year,item.rating.takeIf{it.isNotBlank()}?.let{"★ $it"}).filterNotNull().joinToString("  "),color=Color.Gray,style=MaterialTheme.typography.bodySmall)}}}
