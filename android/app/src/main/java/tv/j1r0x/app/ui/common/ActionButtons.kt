package tv.j1r0x.app.ui.common

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

private val ActionRed = Color(0xFFE50914)
private val ActionDark = Color(0xFF17171C)
private val ActionDisabled = Color(0xFF4A4A4A)
private val ActionDisabledContent = Color(0xFFBDBDBD)
private val FavoriteBorder = Color(0xFFB8B8C0)
private val FavoriteGold = Color(0xFFFFD54F)

@Composable
fun WatchButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    FocusedButtonFrame(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        containerColor = ActionRed,
        unfocusedBorderColor = ActionRed,
    ) {
        Icon(Icons.Default.PlayArrow, contentDescription = null, tint = Color.White)
        Spacer(Modifier.width(8.dp))
        Text("Смотреть", color = Color.White, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun FavoriteButton(
    isFavorite: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    FocusedButtonFrame(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        containerColor = if (isFavorite) ActionRed else ActionDark,
        unfocusedBorderColor = if (isFavorite) ActionRed else FavoriteBorder,
    ) {
        Icon(
            imageVector = if (isFavorite) Icons.Default.Star else Icons.Outlined.StarBorder,
            contentDescription = null,
            tint = if (isFavorite) FavoriteGold else Color.White,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = if (isFavorite) "В избранном" else "Избранное",
            color = Color.White,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
fun RetryButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    FocusedButtonFrame(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        containerColor = ActionRed,
        unfocusedBorderColor = ActionRed,
    ) {
        Text("Повторить", color = Color.White, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun FocusedButtonFrame(
    onClick: () -> Unit,
    modifier: Modifier,
    enabled: Boolean,
    containerColor: Color,
    unfocusedBorderColor: Color,
    content: @Composable () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) 1.04f else 1f, label = "actionFocus")
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .heightIn(min = 52.dp)
            .scale(scale)
            .onFocusChanged { focused = it.isFocused },
        border = BorderStroke(
            width = if (focused) 2.5.dp else 1.5.dp,
            color = if (focused) Color.White else unfocusedBorderColor,
        ),
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = Color.White,
            disabledContainerColor = ActionDisabled,
            disabledContentColor = ActionDisabledContent,
        ),
    ) {
        content()
    }
}
