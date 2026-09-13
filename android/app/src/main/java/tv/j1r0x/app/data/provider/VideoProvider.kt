package tv.j1r0x.app.data.provider

interface VideoProvider {
    val id: String
    val displayName: String
    val priority: Int
    val enabled: Boolean

    suspend fun resolve(
        identity: MediaIdentity,
        request: PlaybackRequest,
    ): ProviderResult
}

/** An expected provider failure which can be classified without parsing text. */
class ProviderException(
    val status: ProviderStatus,
    message: String? = null,
    cause: Throwable? = null,
) : Exception(message, cause)

fun interface ProviderLogger {
    fun log(message: String)

    companion object {
        val NONE = ProviderLogger { }
    }
}

