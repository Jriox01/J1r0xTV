package tv.j1r0x.app.data.provider.rezka

import tv.j1r0x.app.data.provider.MediaIdentity
import tv.j1r0x.app.data.provider.PlaybackRequest
import tv.j1r0x.app.data.provider.ProviderResult
import tv.j1r0x.app.data.provider.VideoProvider

class RezkaProvider(
    private val config: RezkaConfig = RezkaConfig.fromBuildConfig(),
    private val repository: RezkaRepository = RezkaRepository(config),
) : VideoProvider {
    override val id: String = RezkaMapper.PROVIDER_ID
    override val displayName: String = "Rezka"
    override val priority: Int = config.priority
    override val enabled: Boolean
        get() = config.effectiveEnabled

    override suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult = repository.resolve(identity, request)

    suspend fun checkConnection(): RezkaHealthResult = repository.checkConnection()
}
