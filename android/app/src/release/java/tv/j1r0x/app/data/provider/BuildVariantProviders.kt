package tv.j1r0x.app.data.provider

/** Release builds contain only the configured real provider, never mock streams. */
fun buildVariantProviders(realRezkaProvider: VideoProvider): List<VideoProvider> =
    listOf(realRezkaProvider)
