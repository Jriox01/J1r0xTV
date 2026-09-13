package tv.j1r0x.app.data.provider.rezka

import tv.j1r0x.app.BuildConfig

/**
 * Runtime configuration for an explicitly authorised Rezka adapter.
 *
 * BuildConfig values are generated from local.properties. The API key must
 * never be committed to source control. A configured key in a client APK is
 * still extractable, so production secrets belong on an owned server adapter.
 */
data class RezkaConfig(
    val baseUrl: String,
    val apiKey: String?,
    val enabled: Boolean,
    val priority: Int = DEFAULT_PRIORITY,
) {
    /** No adapter call is allowed until both the feature and base URL are set. */
    val effectiveEnabled: Boolean
        get() = enabled && baseUrl.isNotBlank()

    val isApiKeyConfigured: Boolean
        get() = !apiKey.isNullOrBlank()

    /** Deliberately excludes the secret value from logs and debugger output. */
    override fun toString(): String =
        "RezkaConfig(baseUrlConfigured=${baseUrl.isNotBlank()}, apiKeyConfigured=$isApiKeyConfigured, " +
            "enabled=$enabled, effectiveEnabled=$effectiveEnabled, priority=$priority)"

    companion object {
        const val DEFAULT_PRIORITY = 20

        fun fromBuildConfig(): RezkaConfig = RezkaConfig(
            baseUrl = BuildConfig.REZKA_PROVIDER_BASE_URL.trim(),
            apiKey = BuildConfig.REZKA_PROVIDER_API_KEY.trim().takeIf(String::isNotEmpty),
            enabled = BuildConfig.REZKA_PROVIDER_ENABLED,
        )
    }
}
