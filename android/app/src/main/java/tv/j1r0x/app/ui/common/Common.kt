package tv.j1r0x.app.ui.common

import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

@Composable fun isTv():Boolean{val c=LocalContext.current;return c.packageManager.hasSystemFeature("android.software.leanback")||c.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK==Configuration.UI_MODE_TYPE_TELEVISION}
