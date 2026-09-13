package tv.j1r0x.app.utils

import android.util.Base64
import kotlinx.serialization.json.*
import tv.j1r0x.app.domain.model.MediaItem
import java.net.URLEncoder

val appJson = Json { ignoreUnknownKeys = true; isLenient = true }
fun JsonObject.text(vararg keys: String): String = keys.firstNotNullOfOrNull { key ->
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() && it != "null" }
}.orEmpty()
fun imageUrl(value: String): String = when { value.startsWith("//") -> "https:$value"; value.startsWith("/") -> "https://image.tmdb.org/t/p/w500$value"; else -> value }
fun parseMedia(o: JsonObject, fallback: String = "movie"): MediaItem {
    val type = o.text("media_type", "type_movie").takeIf { it in listOf("movie", "tv") } ?: fallback
    val date = o.text("release_date", "first_air_date", "year", "premiere")
    return MediaItem(o.text("id", "movie_id", "tmdb_id", "kinopoisk_id", "kp_id"), type,
        o.text("title", "name", "title_ru", "name_ru", "localized_name", "label").ifBlank { "Без названия" },
        o.text("original_title", "original_name", "title_en", "name_en"), o.text("overview", "description", "plot", "about", "text"),
        imageUrl(o.text("poster_path", "poster", "poster_url", "image", "cover")), imageUrl(o.text("backdrop_path", "backdrop", "backdrop_url", "background")),
        date.take(4), o.text("vote_average", "rating", "kinopoisk_rating", "imdb_rating").take(4), o)
}
fun unwrapItems(root: JsonElement): List<JsonObject> {
    if (root is JsonArray) return root.mapNotNull { it as? JsonObject }
    if (root !is JsonObject) return emptyList()
    for (key in listOf("results", "items", "data", "movies", "content", "list", "docs")) {
        val child = root[key] ?: continue
        val found = unwrapItems(child); if (found.isNotEmpty()) return found
    }
    return emptyList()
}
fun unwrapData(root: JsonElement): JsonObject = (root as? JsonObject)?.let { (it["data"] as? JsonObject) ?: it } ?: JsonObject(emptyMap())
fun query(params: Map<String, String>): String = params.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }
private fun enc(v: String) = URLEncoder.encode(v, "UTF-8").replace("+", "%20").replace("%7E", "~")
    .replace("%21", "!").replace("%27", "'").replace("%28", "(").replace("%29", ")")
fun encodeData(value: JsonObject): String = Base64.encodeToString(value.toString().toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
fun collection(value: JsonElement?, numberKeys: List<String>): List<Pair<String, JsonObject>> = when (value) {
    is JsonObject -> value.mapNotNull { (k, v) -> (v as? JsonObject)?.let { k to it } }
    is JsonArray -> value.mapIndexedNotNull { i, v -> (v as? JsonObject)?.let { o -> (o.text(*numberKeys.toTypedArray()).ifBlank { "${i + 1}" }) to o } }
    else -> emptyList()
}
fun streamUrls(root: JsonElement): List<String> {
    val result = linkedSetOf<String>()
    fun walk(v: JsonElement, key: String = "") { when (v) {
        is JsonObject -> v.forEach { (k,c) -> walk(c,k.lowercase()) }
        is JsonArray -> v.forEach { walk(it,key) }
        is JsonPrimitive -> if (v.isString) { val s=v.content.replace("\\/", "/").substringBefore('|').trim(); if ((s.startsWith("http://") || s.startsWith("https://")) && (key in listOf("url","src","file","stream","hls","dash","master") || listOf(".m3u8",".mp4",".mpd","manifest","playlist").any { it in s.lowercase() })) result += s }
    }}; walk(root); return result.sortedBy { when { ".m3u8" in it.lowercase() -> 0; ".mp4" in it.lowercase() -> 1; ".mpd" in it.lowercase() -> 2; else -> 3 } }
}
