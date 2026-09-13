package tv.j1r0x.app.ui.theme

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val colors=darkColorScheme(primary=Color(0xFFE50914),secondary=Color(0xFFFF5252),background=Color.Black,surface=Color(0xFF141414),onBackground=Color.White,onSurface=Color.White)
@Composable fun J1r0xTheme(content: @Composable () -> Unit)=MaterialTheme(colorScheme=colors,typography=Typography(),content=content)
