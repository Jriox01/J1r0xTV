package tv.j1r0x.app.data.provider

import java.io.IOException
import java.util.concurrent.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderManagerTest {
    private val identity = MediaIdentity(
        imdbId = "tt1234567",
        title = "Test movie",
        year = "2026",
        mediaType = MediaType.MOVIE,
    )
    private val request = PlaybackRequest()

    @Test fun atodoSuccessDoesNotCallRezka() = runTest {
        val calls = mutableListOf<String>()
        val rezka = provider("rezka", 20, calls = calls, result = failure("rezka", ProviderStatus.NO_STREAM))
        val atodo = provider("atodo", 10, calls = calls, result = success("atodo"))

        val result = ProviderManager(listOf(rezka, atodo)).resolve(identity, request)

        assertEquals(listOf("atodo"), calls)
        assertEquals("atodo", result.providerId)
        assertEquals(ProviderStatus.SUCCESS, result.status)
        assertEquals(setOf("atodo"), result.attemptedProviderIds)
    }

    @Test fun atodoNotFoundServerErrorOrNoStreamCallsRezka() = runTest {
        val statuses = listOf(
            ProviderStatus.NOT_FOUND,
            ProviderStatus.NETWORK_ERROR,
            ProviderStatus.SERVER_ERROR,
            ProviderStatus.NO_STREAM,
            ProviderStatus.PLAYBACK_ERROR,
        )

        for (status in statuses) {
            val calls = mutableListOf<String>()
            val result = ProviderManager(
                listOf(
                    provider("atodo", 10, calls, failure("atodo", status)),
                    provider("rezka", 20, calls, success("rezka")),
                ),
            ).resolve(identity, request)

            assertEquals("status=$status", listOf("atodo", "rezka"), calls)
            assertEquals("status=$status", "rezka", result.providerId)
        }
    }

    @Test fun disabledRezkaIsSkippedWithoutBeingMarkedAttempted() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("rezka", 20, calls, success("rezka"), enabled = false),
                provider("next", 30, calls, success("next")),
            ),
        ).resolve(identity, request)

        assertEquals(listOf("next"), calls)
        assertEquals(setOf("next"), result.attemptedProviderIds)
    }

    @Test fun rezkaNotFoundCallsNextRegisteredProvider() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("atodo", 10, calls, success("atodo")),
                provider("rezka", 20, calls, failure("rezka", ProviderStatus.NOT_FOUND)),
                provider("next", 30, calls, success("next")),
            ),
        ).resolve(identity, request, attemptedProviderIds = setOf("atodo"))

        assertEquals(listOf("rezka", "next"), calls)
        assertEquals("next", result.providerId)
    }

    @Test fun atodoTimeoutCallsRezka() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("atodo", 10, calls, thrown = IOException("timeout")),
                provider("rezka", 20, calls, result = success("rezka")),
            ),
        ).resolve(identity, request)

        assertEquals(listOf("atodo", "rezka"), calls)
        assertEquals("rezka", result.providerId)
    }

    @Test fun cancellationStopsTheChainAndIsRethrown() = runTest {
        val calls = mutableListOf<String>()
        val cancellation = CancellationException("cancelled")
        var caught: CancellationException? = null

        try {
            ProviderManager(
                listOf(
                    provider("primary", 10, calls, thrown = cancellation),
                    provider("backup", 20, calls, result = success("backup")),
                ),
            ).resolve(identity, request)
        } catch (error: CancellationException) {
            caught = error
        }

        assertSame(cancellation, caught)
        assertEquals(listOf("primary"), calls)
    }

    @Test fun unexpectedLocalErrorStopsTheChain() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("primary", 10, calls, thrown = IllegalStateException("broken mapper")),
                provider("backup", 20, calls, result = success("backup")),
            ),
        ).resolve(identity, request)

        assertEquals(listOf("primary"), calls)
        assertEquals(ProviderStatus.LOCAL_ERROR, result.status)
        assertTrue(result.cause is IllegalStateException)
    }

    @Test fun preferredProviderIsTriedFirstForHistoryResume() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("primary", 10, calls, success("primary")),
                provider("saved", 20, calls, success("saved")),
            ),
        ).resolve(identity, request, preferredProviderId = "saved")

        assertEquals(listOf("saved"), calls)
        assertEquals("saved", result.providerId)
    }

    @Test fun unavailableSavedProviderFallsBackToRegisteredPriorityOrder() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("atodo", 10, calls, success("atodo")),
                provider("saved", 20, calls, success("saved"), enabled = false),
            ),
        ).resolve(identity, request, preferredProviderId = "saved")

        assertEquals(listOf("atodo"), calls)
        assertEquals("atodo", result.providerId)
    }

    @Test fun alreadyAttemptedProviderIsNeverCalledAgain() = runTest {
        val calls = mutableListOf<String>()
        val result = ProviderManager(
            listOf(
                provider("primary", 10, calls, success("primary")),
                provider("backup", 20, calls, success("backup")),
            ),
        ).resolve(identity, request, attemptedProviderIds = setOf("primary"))

        assertEquals(listOf("backup"), calls)
        assertEquals(setOf("primary", "backup"), result.attemptedProviderIds)
    }

    @Test fun playbackFallbackExcludesTheFailedProvider() = runTest {
        val calls = mutableListOf<String>()
        val manager = ProviderManager(
            listOf(
                provider("primary", 10, calls, success("primary")),
                provider("backup", 20, calls, success("backup")),
            ),
        )

        val result = manager.resolveAfterPlaybackError(
            identity = identity,
            request = request,
            failedProviderId = "primary",
        )

        assertEquals(listOf("backup"), calls)
        assertEquals(setOf("primary", "backup"), result.attemptedProviderIds)
        assertEquals("backup", result.providerId)
    }

    @Test fun successWithoutStreamIsClassifiedAsNoStreamAndFallsBack() = runTest {
        val calls = mutableListOf<String>()
        val invalidSuccess = ProviderResult(providerId = "primary", status = ProviderStatus.SUCCESS)
        val result = ProviderManager(
            listOf(
                provider("primary", 10, calls, invalidSuccess),
                provider("backup", 20, calls, success("backup")),
            ),
        ).resolve(identity, request)

        assertEquals(listOf("primary", "backup"), calls)
        assertEquals("backup", result.providerId)
    }

    @Test fun successWithBlankStreamUrlIsClassifiedAsNoStream() = runTest {
        val calls = mutableListOf<String>()
        val blankStream = ProviderResult.success(
            providerId = "primary",
            stream = ProviderStream("   "),
        )
        val result = ProviderManager(
            listOf(
                provider("primary", 10, calls, blankStream),
                provider("backup", 20, calls, success("backup")),
            ),
        ).resolve(identity, request)

        assertEquals(listOf("primary", "backup"), calls)
        assertEquals("backup", result.providerId)
    }

    @Test fun providerIdFromProviderCannotSpoofManagerResult() = runTest {
        val result = ProviderManager(
            listOf(provider("primary", 10, result = success("wrong-id"))),
        ).resolve(identity, request)

        assertEquals("primary", result.providerId)
        assertFalse("wrong-id" in result.attemptedProviderIds)
    }

    private fun provider(
        id: String,
        priority: Int,
        calls: MutableList<String> = mutableListOf(),
        result: ProviderResult? = null,
        thrown: Exception? = null,
        enabled: Boolean = true,
    ) = object : VideoProvider {
        override val id = id
        override val displayName = id.replaceFirstChar { it.uppercase() }
        override val priority = priority
        override val enabled = enabled

        override suspend fun resolve(identity: MediaIdentity, request: PlaybackRequest): ProviderResult {
            calls += id
            if (thrown != null) throw thrown
            return checkNotNull(result)
        }
    }

    private fun success(id: String) = ProviderResult.success(
        providerId = id,
        stream = ProviderStream("https://example.test/video.m3u8", ProviderStreamType.HLS),
    )

    private fun failure(id: String, status: ProviderStatus) =
        ProviderResult.failure(providerId = id, status = status)
}
