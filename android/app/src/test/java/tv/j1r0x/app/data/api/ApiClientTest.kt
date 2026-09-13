package tv.j1r0x.app.data.api

import okhttp3.Protocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLProtocolException

class ApiClientTest {
    @Test fun atodoClientUsesOnlyHttp11AndExpectedTimeouts() {
        val client = ApiClient.okHttp
        assertEquals(listOf(Protocol.HTTP_1_1), client.protocols)
        assertTrue(client.retryOnConnectionFailure)
        assertEquals(20_000, client.connectTimeoutMillis)
        assertEquals(30_000, client.readTimeoutMillis)
        assertEquals(20_000, client.writeTimeoutMillis)
        assertEquals(40_000, client.callTimeoutMillis)
    }

    @Test fun recognizesOnlyRequestedResetErrors() {
        assertTrue(isResetIOException(IOException("stream was reset: INTERNAL_ERROR")))
        assertTrue(isResetIOException(IOException("Connection reset by peer")))
        assertTrue(isResetIOException(IOException("unexpected end of stream on https://api.atodo.fun/...")))
        assertTrue(isResetIOException(SSLProtocolException("Read error")))
        assertFalse(isResetIOException(IOException("timeout")))
    }
}
