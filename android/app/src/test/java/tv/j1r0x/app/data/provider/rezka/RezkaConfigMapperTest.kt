package tv.j1r0x.app.data.provider.rezka

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RezkaConfigMapperTest {
    @Test
    fun `provider is effective only when enabled and base URL is present`() {
        assertFalse(RezkaConfig("", null, enabled = true).effectiveEnabled)
        assertFalse(RezkaConfig("https://adapter.example", null, enabled = false).effectiveEnabled)
        assertTrue(RezkaConfig("https://adapter.example", null, enabled = true).effectiveEnabled)
    }

    @Test
    fun `config string never contains API key`() {
        val secret = "do-not-print-this-key"
        val value = RezkaConfig("https://adapter.example", secret, enabled = true).toString()

        assertFalse(value.contains(secret))
        assertTrue(value.contains("apiKeyConfigured=true"))
    }

    @Test
    fun `technical translation name is replaced with readable fallback`() {
        val translation = RezkaTranslation(
            id = "0123456789abcdef0123456789abcdef",
            name = "0123456789abcdef0123456789abcdef",
        )

        assertEquals("Озвучка №2", RezkaMapper.translationDisplayName(translation, 1))
    }

    @Test
    fun `mapper appends readable language and drops blank stream`() {
        val media = RezkaMediaResult(
            id = "allowed-adapter-id",
            mediaType = RezkaMediaType.MOVIE,
            title = "Movie",
            translations = listOf(
                RezkaTranslation(
                    name = "Дубляж",
                    language = "ru",
                    streams = listOf(RezkaStream(url = "  ")),
                ),
            ),
        )

        val mapped = RezkaMapper.toProviderMedia(media)

        assertEquals("Дубляж • RU", mapped.translations.single().name)
        assertTrue(mapped.translations.single().streams.isEmpty())
        assertNull(RezkaMapper.toProviderStream(RezkaStream(url = "")))
    }
}
