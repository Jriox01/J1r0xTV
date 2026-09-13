package tv.j1r0x.app.utils

import kotlinx.serialization.json.JsonObject

private val HEX_VALUE = Regex("^[0-9a-fA-F]+$")
private val HASH_LIKE_VALUE = Regex("^[0-9a-fA-F:_-]+$")
private val PREFIXED_HASH = Regex("^(?:md5|sha(?:1|224|256|384|512)?)[_:-]?[0-9a-fA-F]+$", RegexOption.IGNORE_CASE)

fun isTechnicalValue(value: String, translationId: String = ""): Boolean {
    val normalized = value.trim()
    if (normalized.isBlank()) return true
    if (translationId.isNotBlank() && normalized == translationId.trim()) return true
    if (normalized.length > 24 && (HEX_VALUE.matches(normalized) || HASH_LIKE_VALUE.matches(normalized))) return true
    if (PREFIXED_HASH.matches(normalized)) return true
    if (normalized.length > 40) {
        val mostlyHex = normalized.count { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        if (mostlyHex.toDouble() / normalized.length >= 0.8) return true
    }
    return false
}

fun translationDisplayName(translation: JsonObject, index: Int): String {
    val translationId = translation.text("translation_id", "id", "hash")
    val displayName = listOf(
        "translation_name", "name", "title", "label",
        "voice", "studio", "quality",
    ).firstNotNullOfOrNull { field ->
        translation.text(field).trim().takeIf { it.isNotBlank() && !isTechnicalValue(it, translationId) }
    } ?: return "Озвучка №${index + 1}"

    val language = translation.text("language", "lang", "language_code", "audio_language")
        .trim().uppercase()
        .takeIf { it.isNotBlank() && !isTechnicalValue(it, translationId) }

    return if (language != null && !displayName.contains(language, ignoreCase = true)) {
        "$displayName • $language"
    } else {
        displayName
    }
}

fun translationStableKey(translation: JsonObject, index: Int): String {
    val id = translation.text("translation_id", "id").trim()
    return id.ifBlank { "translation-index:$index" }
}
