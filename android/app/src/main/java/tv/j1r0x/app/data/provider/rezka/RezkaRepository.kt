package tv.j1r0x.app.data.provider.rezka

import tv.j1r0x.app.data.provider.MediaIdentity
import tv.j1r0x.app.data.provider.PlaybackRequest
import tv.j1r0x.app.data.provider.ProviderResult
import tv.j1r0x.app.data.provider.ProviderStatus

/**
 * Safe placeholder until authorised API documentation is supplied.
 *
 * No network client is accepted or invoked, preventing an accidentally guessed
 * endpoint from reaching a third-party service.
 */
class RezkaRepository(
    private val config: RezkaConfig,
) {
    @Suppress("UNUSED_PARAMETER")
    suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult {
        if (!config.effectiveEnabled) {
            return ProviderResult.failure(
                providerId = RezkaMapper.PROVIDER_ID,
                status = ProviderStatus.DISABLED,
                message = "Rezka provider is disabled or has no base URL",
            )
        }
        return ProviderResult.failure(
            providerId = RezkaMapper.PROVIDER_ID,
            status = ProviderStatus.NO_STREAM,
            message = "Rezka API documentation has not been configured",
        )
    }

    /** A real health request must not be invented without a documented endpoint. */
    suspend fun checkConnection(): RezkaHealthResult = when {
        !config.enabled -> RezkaHealthResult(
            status = RezkaHealthStatus.DISABLED,
            message = "Rezka provider is disabled",
        )
        config.baseUrl.isBlank() -> RezkaHealthResult(
            status = RezkaHealthStatus.NOT_CONFIGURED,
            message = "Rezka base URL is not configured",
        )
        else -> RezkaHealthResult(
            status = RezkaHealthStatus.DOCUMENTATION_REQUIRED,
            message = "A documented health-check endpoint is required",
        )
    }
}
