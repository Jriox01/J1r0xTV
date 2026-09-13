package tv.j1r0x.app.data.provider

import tv.j1r0x.app.data.provider.rezka.MockRezkaProvider
import tv.j1r0x.app.data.provider.rezka.debugRezkaController

/** Uses the real adapter when configured; otherwise exposes the opt-in debug mock. */
fun buildVariantProviders(realRezkaProvider: VideoProvider): List<VideoProvider> =
    if (realRezkaProvider.enabled) {
        listOf(realRezkaProvider)
    } else {
        listOf(MockRezkaProvider(debugRezkaController))
    }
