package tv.j1r0x.app.ui.player

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import tv.j1r0x.app.domain.model.PlaybackSelection

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@Composable
fun PlayerScreen(
    selection: PlaybackSelection,
    statusMessage: String?,
    onStarted: () -> Unit,
    onProgress: (Long, Long) -> Unit,
    onExit: (Long, Long) -> Unit,
    onPlaybackError: (PlaybackException, Long) -> Unit,
) {
    val context = LocalContext.current
    val currentOnStarted by rememberUpdatedState(onStarted)
    val currentOnProgress by rememberUpdatedState(onProgress)
    val currentOnExit by rememberUpdatedState(onExit)
    val currentOnPlaybackError by rememberUpdatedState(onPlaybackError)
    val player = remember(selection.streamUrl, selection.streamHeaders) {
        val dataSourceFactory = DefaultHttpDataSource.Factory().apply {
            if (selection.streamHeaders.isNotEmpty()) {
                setDefaultRequestProperties(selection.streamHeaders)
            }
        }
        ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory))
            .build()
            .apply {
                setMediaItem(MediaItem.fromUri(selection.streamUrl))
                prepare()
                seekTo(selection.resumePositionMs)
                playWhenReady = true
            }
    }
    var controlsVisible by remember { mutableStateOf(true) }
    var exitReported by remember(player) { mutableStateOf(false) }

    fun positionAndDuration(): Pair<Long, Long> =
        player.currentPosition.coerceAtLeast(0L) to player.duration.coerceAtLeast(0L)

    fun exitPlayer() {
        if (exitReported) return
        exitReported = true
        val (position, duration) = positionAndDuration()
        currentOnExit(position, duration)
    }

    DisposableEffect(player) {
        var startedReported = false
        var errorReported = false
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying && !startedReported) {
                    startedReported = true
                    currentOnStarted()
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                if (!errorReported) {
                    errorReported = true
                    currentOnPlaybackError(error, player.currentPosition.coerceAtLeast(0L))
                }
            }
        }
        player.addListener(listener)
        onDispose {
            val (position, duration) = positionAndDuration()
            currentOnProgress(position, duration)
            player.removeListener(listener)
            player.release()
        }
    }

    BackHandler {
        if (controlsVisible) controlsVisible = false else exitPlayer()
    }

    Box(
        Modifier
            .fillMaxSize()
            .pointerInput(player) {
                detectTapGestures(onDoubleTap = { offset ->
                    if (offset.x < size.width / 2) {
                        player.seekTo((player.currentPosition - 10_000).coerceAtLeast(0))
                    } else {
                        player.seekTo(player.currentPosition + 10_000)
                    }
                })
            }
            .onPreviewKeyEvent { event ->
                if (event.nativeKeyEvent.action != KeyEvent.ACTION_DOWN) {
                    return@onPreviewKeyEvent false
                }
                when (event.nativeKeyEvent.keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT -> {
                        player.seekTo((player.currentPosition - 10_000).coerceAtLeast(0))
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        player.seekTo(player.currentPosition + 10_000)
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        controlsVisible = true
                        if (player.isPlaying) player.pause() else player.play()
                        true
                    }
                    else -> false
                }
            },
    ) {
        AndroidView(
            factory = { PlayerView(it).apply { this.player = player; useController = true } },
            update = { it.useController = controlsVisible },
            modifier = Modifier.fillMaxSize(),
        )
        statusMessage?.let { message ->
            Text(
                text = message,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(24.dp)
                    .background(Color(0xDD17171C))
                    .padding(horizontal = 20.dp, vertical = 12.dp),
            )
        }
    }
}
