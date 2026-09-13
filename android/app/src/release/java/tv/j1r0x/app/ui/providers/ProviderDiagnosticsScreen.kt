package tv.j1r0x.app.ui.providers

import androidx.compose.runtime.Composable
import tv.j1r0x.app.ui.AppViewModel

fun providersDebugScreenEnabled(): Boolean = false

@Composable
fun ProviderDiagnosticsScreen(vm: AppViewModel, onBack: () -> Unit) = Unit
