package tv.j1r0x.app.ui.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import tv.j1r0x.app.data.provider.ProviderDiagnostic
import tv.j1r0x.app.data.provider.rezka.MockRezkaMode
import tv.j1r0x.app.data.provider.rezka.debugRezkaController
import tv.j1r0x.app.ui.AppViewModel

fun providersDebugScreenEnabled(): Boolean = true

@Composable
fun ProviderDiagnosticsScreen(vm: AppViewModel, onBack: () -> Unit) {
    var refresh by remember { mutableIntStateOf(0) }
    var healthMessage by remember { mutableStateOf<String?>(null) }
    val diagnostics = remember(refresh) { vm.providerDiagnostics() }
    val rezkaConfig = remember(refresh) { vm.rezkaConfigurationSummary() }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OutlinedButton(onClick = onBack) { Text("← Назад") }
        Text("Провайдеры", style = MaterialTheme.typography.headlineMedium)
        diagnostics.forEach { diagnostic ->
            ProviderCard(
                diagnostic = diagnostic,
                extra = if (diagnostic.id == "rezka") {
                    listOf(
                        "baseUrl настроен: ${yesNo(rezkaConfig.baseUrlConfigured)}",
                        "API key настроен: ${yesNo(rezkaConfig.apiKeyConfigured)}",
                    )
                } else {
                    emptyList()
                },
            )
        }

        Text("Mock Rezka (только debug)", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Включён")
            Switch(
                checked = debugRezkaController.enabled,
                onCheckedChange = { debugRezkaController.enabled = it; refresh++ },
            )
        }
        MockRezkaMode.entries.forEach { mode ->
            OutlinedButton(
                onClick = {
                    debugRezkaController.mode = mode
                    debugRezkaController.enabled = true
                    refresh++
                },
            ) {
                Text(if (debugRezkaController.mode == mode) "✓ ${mode.name}" else mode.name)
            }
        }

        Button(onClick = { healthMessage = vm.providerHealthCheckMessage() }) {
            Text("Проверить подключение")
        }
        healthMessage?.let { Text(it) }
        Text(
            "Сетевой health-check не выполняется, пока не предоставлен документированный endpoint.",
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun ProviderCard(diagnostic: ProviderDiagnostic, extra: List<String>) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(diagnostic.displayName, style = MaterialTheme.typography.titleLarge)
            Text("Включён: ${yesNo(diagnostic.enabled)}")
            Text("Приоритет: ${diagnostic.priority}")
            Text("Последний статус: ${diagnostic.lastStatus?.name ?: "ещё не запускался"}")
            Text("Время ответа: ${diagnostic.responseTimeMs?.let { "$it мс" } ?: "—"}")
            extra.forEach { Text(it) }
        }
    }
}

private fun yesNo(value: Boolean): String = if (value) "да" else "нет"
