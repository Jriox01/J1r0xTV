package tv.j1r0x.app.data.provider

import java.io.IOException
import java.util.concurrent.CancellationException

/**
 * Resolves playback through providers once, in deterministic priority order.
 * The manager owns no retry loop: each provider id can be attempted at most
 * once for a resolution chain.
 */
class ProviderManager(
    providers: List<VideoProvider>,
    private val logger: ProviderLogger = ProviderLogger.NONE,
    private val clockMs: () -> Long = System::currentTimeMillis,
) {
    private val registeredProviders = providers
        .withIndex()
        .sortedWith(compareBy<IndexedValue<VideoProvider>> { it.value.priority }.thenBy { it.index })
        .map { it.value }
    private val lastDiagnostics = mutableMapOf<String, ProviderDiagnostic>()

    @Synchronized
    fun diagnostics(): List<ProviderDiagnostic> = registeredProviders.map { provider ->
        lastDiagnostics[provider.id]?.copy(
            displayName = provider.displayName,
            priority = provider.priority,
            enabled = provider.enabled,
        ) ?: ProviderDiagnostic(
            id = provider.id,
            displayName = provider.displayName,
            priority = provider.priority,
            enabled = provider.enabled,
        )
    }

    fun registerStatus(
        providerId: String,
        status: ProviderStatus,
        responseTimeMs: Long? = null,
    ) {
        registeredProviders.firstOrNull { it.id == providerId }?.let { provider ->
            recordDiagnostic(provider, status, responseTimeMs)
        }
    }

    suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
        preferredProviderId: String? = null,
        attemptedProviderIds: Set<String> = emptySet(),
        excludedProviderIds: Set<String> = emptySet(),
    ): ProviderResult {
        val attempted = attemptedProviderIds.toMutableSet()
        val ordered = orderedProviders(preferredProviderId)
        var lastFallbackResult: ProviderResult? = null

        for (provider in ordered) {
            if (provider.id in attempted || provider.id in excludedProviderIds) continue
            if (!provider.enabled) {
                logger.log("${provider.displayName} disabled")
                recordDiagnostic(provider, ProviderStatus.DISABLED, null)
                continue
            }

            attempted += provider.id
            logger.log("Trying provider: ${provider.id}")
            val startedAt = clockMs()
            val result = try {
                provider.resolve(identity, request)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: ProviderException) {
                ProviderResult.failure(
                    providerId = provider.id,
                    status = error.status,
                    message = error.message,
                    cause = error,
                )
            } catch (error: IOException) {
                ProviderResult.failure(
                    providerId = provider.id,
                    status = ProviderStatus.NETWORK_ERROR,
                    message = error.message,
                    cause = error,
                )
            } catch (error: Exception) {
                ProviderResult.failure(
                    providerId = provider.id,
                    status = ProviderStatus.LOCAL_ERROR,
                    message = error.message,
                    cause = error,
                )
            }

            val elapsed = (clockMs() - startedAt).coerceAtLeast(0L)
            val normalized = result.copy(
                providerId = provider.id,
                responseTimeMs = result.responseTimeMs ?: elapsed,
                attemptedProviderIds = attempted.toSet(),
            )
            recordDiagnostic(provider, normalized.status, normalized.responseTimeMs)

            if (normalized.isSuccess) {
                logger.log("${provider.displayName} succeeded")
                normalized.translation?.name?.takeIf { it.isNotBlank() }?.let {
                    logger.log("Translation: $it")
                }
                normalized.season?.number?.let { logger.log("Season: $it") }
                normalized.episode?.number?.let { logger.log("Episode: $it") }
                normalized.stream?.type?.let { logger.log("Stream type: $it") }
                return normalized
            }

            // SUCCESS without a playable stream is a provider contract error,
            // but it is safe to let another provider resolve the content.
            val classified = if (normalized.status == ProviderStatus.SUCCESS) {
                normalized.copy(
                    status = ProviderStatus.NO_STREAM,
                    message = normalized.message ?: "Provider returned no stream",
                )
            } else {
                normalized
            }
            logger.log("${provider.displayName} failed: ${classified.status}")

            if (!classified.status.permitsFallback) return classified
            lastFallbackResult = classified
        }

        return lastFallbackResult?.copy(attemptedProviderIds = attempted.toSet())
            ?: ProviderResult.failure(
                providerId = "",
                status = ProviderStatus.NO_STREAM,
                message = "No enabled provider is available",
            ).copy(attemptedProviderIds = attempted.toSet())
    }

    /**
     * Continues the same attempt after a stream failed in the player. The
     * failed provider is always excluded, so it cannot be selected again.
     */
    suspend fun resolveAfterPlaybackError(
        identity: MediaIdentity,
        request: PlaybackRequest,
        failedProviderId: String,
        attemptedProviderIds: Set<String> = emptySet(),
    ): ProviderResult = resolve(
        identity = identity,
        request = request,
        attemptedProviderIds = attemptedProviderIds + failedProviderId,
        excludedProviderIds = setOf(failedProviderId),
    )

    private fun orderedProviders(preferredProviderId: String?): List<VideoProvider> {
        if (preferredProviderId == null) return registeredProviders
        val preferred = registeredProviders.filter { it.id == preferredProviderId }
        if (preferred.isEmpty()) return registeredProviders
        return preferred + registeredProviders.filterNot { it.id == preferredProviderId }
    }

    @Synchronized
    private fun recordDiagnostic(
        provider: VideoProvider,
        status: ProviderStatus,
        responseTimeMs: Long?,
    ) {
        lastDiagnostics[provider.id] = ProviderDiagnostic(
            id = provider.id,
            displayName = provider.displayName,
            priority = provider.priority,
            enabled = provider.enabled,
            lastStatus = status,
            responseTimeMs = responseTimeMs,
        )
    }
}

data class ProviderDiagnostic(
    val id: String,
    val displayName: String,
    val priority: Int,
    val enabled: Boolean,
    val lastStatus: ProviderStatus? = null,
    val responseTimeMs: Long? = null,
)
