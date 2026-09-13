package tv.j1r0x.app.data.provider.rezka

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tv.j1r0x.app.data.provider.MediaIdentity
import tv.j1r0x.app.data.provider.MediaType
import tv.j1r0x.app.data.provider.PlaybackRequest
import tv.j1r0x.app.data.provider.ProviderManager
import tv.j1r0x.app.data.provider.ProviderResult
import tv.j1r0x.app.data.provider.ProviderStatus
import tv.j1r0x.app.data.provider.ProviderStreamType
import tv.j1r0x.app.data.provider.VideoProvider
import tv.j1r0x.app.data.provider.buildVariantProviders

class MockRezkaProviderTest {
    private val identity = MediaIdentity(
        title = "Test",
        mediaType = MediaType.MOVIE,
    )

    @Test
    fun `mock is disabled by default`() {
        assertFalse(MockRezkaProvider(MockRezkaController()).enabled)
    }

    @Test
    fun `success movie returns public HLS test stream`() = runTest {
        val provider = MockRezkaProvider(
            MockRezkaController(enabled = true, mode = MockRezkaMode.SUCCESS_MOVIE),
        )

        val result = provider.resolve(identity, PlaybackRequest())

        assertTrue(result.isSuccess)
        assertEquals(ProviderStreamType.HLS, result.stream?.type)
        assertTrue(result.stream?.url?.startsWith("https://devstreaming-cdn.apple.com/") == true)
    }

    @Test
    fun `atodo server error falls back through manager to debug mock`() = runTest {
        val calls = mutableListOf<String>()
        val atodo = object : VideoProvider {
            override val id = "atodo"
            override val displayName = "Atodo"
            override val priority = 10
            override val enabled = true

            override suspend fun resolve(
                identity: MediaIdentity,
                request: PlaybackRequest,
            ): ProviderResult {
                calls += id
                return ProviderResult.failure(id, ProviderStatus.SERVER_ERROR, "HTTP 500")
            }
        }
        val mock = MockRezkaProvider(
            MockRezkaController(enabled = true, mode = MockRezkaMode.SUCCESS_MOVIE),
        )

        val result = ProviderManager(listOf(mock, atodo)).resolve(identity, PlaybackRequest())

        assertEquals(listOf("atodo"), calls)
        assertEquals("rezka", result.providerId)
        assertEquals(setOf("atodo", "rezka"), result.attemptedProviderIds)
        assertEquals(ProviderStatus.SUCCESS, result.status)
        assertEquals(ProviderStreamType.HLS, result.stream?.type)
    }

    @Test
    fun `failure modes are deterministic`() = runTest {
        val controller = MockRezkaController(enabled = true, mode = MockRezkaMode.SERVER_ERROR)
        val provider = MockRezkaProvider(controller)

        assertEquals(ProviderStatus.SERVER_ERROR, provider.resolve(identity, PlaybackRequest()).status)

        controller.mode = MockRezkaMode.NO_STREAM
        assertEquals(ProviderStatus.NO_STREAM, provider.resolve(identity, PlaybackRequest()).status)
    }

    @Test
    fun `variant factory registers exactly one rezka provider`() {
        val enabledReal = stubRealProvider(enabled = true)
        assertEquals(listOf(enabledReal), buildVariantProviders(enabledReal))

        val debugFallback = buildVariantProviders(stubRealProvider(enabled = false))
        assertEquals(1, debugFallback.size)
        assertEquals("rezka", debugFallback.single().id)
        assertFalse(debugFallback.single().enabled)
    }

    private fun stubRealProvider(enabled: Boolean): VideoProvider = object : VideoProvider {
        override val id = "rezka"
        override val displayName = "Rezka"
        override val priority = 20
        override val enabled = enabled

        override suspend fun resolve(
            identity: MediaIdentity,
            request: PlaybackRequest,
        ) = ProviderResult.failure(id, ProviderStatus.NO_STREAM)
    }
}
