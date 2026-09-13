package tv.j1r0x.app.data.api

import android.util.Log
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import retrofit2.Retrofit
import retrofit2.converter.scalars.ScalarsConverterFactory
import java.io.EOFException
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLProtocolException

private const val TAG = "J1r0xApi"
private const val RESET_RETRY_DELAY_MS = 400L
private const val RESET_MESSAGE = "Сервер временно сбросил соединение. Нажмите “Повторить”."

private class SessionCookieJar : CookieJar {
    private val cookies = mutableMapOf<String, Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, values: List<Cookie>) {
        values.forEach { cookies[it.name] = it }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> =
        cookies.values.filter { it.matches(url) }
}

internal fun isResetIOException(error: IOException): Boolean {
    val message = error.message.orEmpty().lowercase()
    return error is EOFException ||
        error is SSLProtocolException ||
        "stream was reset" in message ||
        "internal_error" in message ||
        "connection reset" in message ||
        "unexpected end of stream" in message
}

private fun HttpUrl.withoutSensitiveQuery(): String =
    newBuilder().query(null).build().toString()

object ApiClient {
    const val BASE_URL = "https://api.atodo.fun/"

    val okHttp: OkHttpClient by lazy {
        OkHttpClient.Builder()
            // api.atodo.fun intermittently resets HTTP/2 streams. This client is API-only;
            // Media3 creates and owns its separate playback networking stack.
            .protocols(listOf(Protocol.HTTP_1_1))
            .retryOnConnectionFailure(true)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .callTimeout(40, TimeUnit.SECONDS)
            .cookieJar(SessionCookieJar())
            .addInterceptor { chain ->
                val request = chain.request().newBuilder()
                    .header("Accept", "application/json, text/plain, */*")
                    .header("Accept-Language", "ru-RU,ru;q=0.9,en;q=0.8")
                    // Atodo intermittently truncates gzip/chunked keep-alive responses.
                    // A fresh, uncompressed HTTP/1.1 response is reliable and affects API calls only.
                    .header("Accept-Encoding", "identity")
                    .header("Connection", "close")
                    .header("Origin", "https://atodo.fun")
                    .header("Referer", "https://atodo.fun/fun.html")
                    .header(
                        "User-Agent",
                        "Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 " +
                            "Chrome/150.0.0.0 Safari/537.36",
                    )
                    .build()
                chain.proceed(request)
            }
            .addInterceptor { chain ->
                val request = chain.request()
                val safeUrl = request.url.withoutSensitiveQuery()
                var attempt = 1
                var retryingAfterReset = false
                var completed: Response? = null

                while (completed == null) {
                    try {
                        val response = chain.proceed(request)
                        Log.d(
                            TAG,
                            "url=$safeUrl protocol=${response.protocol} attempt=$attempt " +
                                "status=${response.code}",
                        )
                        completed = response
                    } catch (error: IOException) {
                        Log.w(
                            TAG,
                            "url=$safeUrl protocol=${Protocol.HTTP_1_1} attempt=$attempt " +
                                "io=${error.javaClass.simpleName}",
                        )

                        val isReset = isResetIOException(error)
                        if (attempt >= 2 || !isReset) {
                            if (isReset || retryingAfterReset) {
                                throw IOException(RESET_MESSAGE, error)
                            }
                            throw error
                        }

                        try {
                            Thread.sleep(RESET_RETRY_DELAY_MS)
                        } catch (interrupted: InterruptedException) {
                            Thread.currentThread().interrupt()
                            throw IOException("Запрос был прерван", interrupted)
                        }
                        retryingAfterReset = true
                        attempt++
                    }
                }
                completed
            }
            .build()
    }

    val service: ApiService by lazy {
        Retrofit.Builder()
            .baseUrl(BASE_URL)
            .client(okHttp)
            .addConverterFactory(ScalarsConverterFactory.create())
            .build()
            .create(ApiService::class.java)
    }
}
