package tv.j1r0x.app.utils

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslationUtilsTest {
    @Test fun usesRealTranslationNameBeforeTechnicalId() {
        val value = buildJsonObject {
            put("translation_id", "686476625fd094d183d0b1d0bbd18fd0b6205bd097d0b2d183d0ba20d1812054535d")
            put("translation_name", "Дубляж [Звук с TS]")
        }
        assertEquals("Дубляж [Звук с TS]", translationDisplayName(value, 0))
    }

    @Test fun rejectsHashesAndFallsBackToNumber() {
        val hash = "686476625fd094d183d0b1d0bbd18fd0b6205bd097d0b2d183d0ba20d1812054535d"
        val value = buildJsonObject { put("translation_id", hash); put("name", hash) }
        assertTrue(isTechnicalValue(hash, hash))
        assertEquals("Озвучка №2", translationDisplayName(value, 1))
    }

    @Test fun addsReadableLanguageAndKeepsNormalNames() {
        val value = buildJsonObject { put("studio", "LostFilm"); put("language", "ru") }
        assertFalse(isTechnicalValue("LostFilm"))
        assertEquals("LostFilm • RU", translationDisplayName(value, 0))
    }
}
