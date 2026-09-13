package tv.j1r0x.app.data.repository

import android.util.Log
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*
import tv.j1r0x.app.data.api.ApiClient
import tv.j1r0x.app.data.api.ApiHttpException
import tv.j1r0x.app.domain.model.MediaItem
import tv.j1r0x.app.domain.model.SourceOption
import tv.j1r0x.app.utils.*

class MediaRepository {
    private val api = ApiClient.service
    private val detailsCache = mutableMapOf<Pair<String,String>, MediaItem>()
    private suspend fun request(path: String, params: Map<String,String> = emptyMap()): JsonElement {
        val url = ApiClient.BASE_URL + path.trimStart('/') + if (params.isEmpty()) "" else "?${query(params)}"
        if (tv.j1r0x.app.BuildConfig.DEBUG) Log.d("J1r0xApi", "GET $path")
        for (attempt in 1..2) {
            val response = api.get(url)
            if (response.isSuccessful) {
                val body = response.body().orEmpty()
                if (body.isBlank()) throw IllegalStateException("Сервер вернул пустой ответ")
                return try { appJson.parseToJsonElement(body) } catch (_: Exception) {
                    throw IllegalStateException("Сервер вернул повреждённый JSON")
                }
            }
            val status = response.code()
            response.errorBody()?.close()
            val retryable = status in setOf(500, 502, 503, 504)
            if (retryable && attempt == 1) {
                if (tv.j1r0x.app.BuildConfig.DEBUG) {
                    Log.w("J1r0xApi", "endpoint=$path http=$status retryAttempt=2")
                }
                delay(500)
                continue
            }
            throw ApiHttpException(status, path)
        }
        error("Unreachable API retry state")
    }
    suspend fun catalog(type: String, page: Int = 1) = unwrapItems(request("api/list", mapOf("type_movie" to type, "page" to "$page"))).map { parseMedia(it,type) }
    suspend fun search(value: String, page: Int = 1) = unwrapItems(request("api/search", mapOf("query" to value, "page" to "$page"))).map { parseMedia(it) }
    suspend fun details(type: String, id: String): MediaItem = detailsCache[type to id] ?: run {
        var root = request("api/details/$type/$id")
        val rootObject = root as? JsonObject
        if (rootObject != null) for (key in listOf("data","result","item","movie")) { val n=rootObject[key]; if(n is JsonObject){root=n;break} }
        val value=parseMedia(root as? JsonObject ?: error("Неизвестный формат карточки"),type); detailsCache[type to id]=value; value
    }
    fun canonical(item: MediaItem): Map<String,String> {
        val raw=item.raw; val external=raw["external_ids"] as? JsonObject
        val imdb=raw.text("imdb_id").ifBlank { external?.text("imdb_id").orEmpty() }
        val date=raw.text("first_air_date","release_date","year").ifBlank { item.year }
        return linkedMapOf("id" to item.id,"title" to raw.text("title","name").ifBlank { item.title },
            "original_title" to raw.text("original_title","original_name").ifBlank { item.originalTitle },
            "original_language" to raw.text("original_language"),"imdb_id" to imdb,"year" to date.take(4),"type" to item.type).filterValues { it.isNotBlank() }
    }
    suspend fun sources(input: MediaItem): Pair<MediaItem,List<SourceOption>> {
        val item=if(input.type=="tv") details("tv",input.id) else input
        val info=canonical(item)
        val data=unwrapData(request("api/source/list",info)); val balancers=data["balancers"] as? JsonArray ?: JsonArray(emptyList())
        return item.copy(canonicalInfo=info) to balancers.mapNotNull { (it as? JsonObject)?.let { o -> o.text("id","source_id","key").takeIf(String::isNotBlank)?.let { SourceOption(it,o.text("name","title","label").ifBlank { it }) } } }
    }
    suspend fun source(item: MediaItem, sourceId: String): JsonObject = unwrapData(request("api/source/$sourceId",item.canonicalInfo.ifEmpty { canonical(item) }))
    suspend fun resolve(sourceId: String, data: JsonObject): JsonObject = unwrapData(request("api/source/$sourceId",mapOf("data" to encodeData(data))))
}
