package tv.j1r0x.app.data.api

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApiErrorsTest {
    @Test fun serverErrorsAreHumanReadable() {
        val message = apiHttpUserMessage(500)
        assertTrue(message.contains("Сервер временно"))
        assertTrue(message.contains("Повторить"))
        assertFalse(message.contains("HTTP 500"))
    }
}
