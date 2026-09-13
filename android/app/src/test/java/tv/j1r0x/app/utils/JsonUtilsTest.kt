package tv.j1r0x.app.utils

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class JsonUtilsTest {
    @Test fun parsesCatalogAliasesAndImages(){val item=parseMedia(buildJsonObject{put("id","7");put("name","Тест");put("poster_path","/p.jpg");put("first_air_date","2022-10-01")},"tv");assertEquals("7",item.id);assertEquals("tv",item.type);assertEquals("https://image.tmdb.org/t/p/w500/p.jpg",item.poster);assertEquals("2022",item.year)}
    @Test fun supportsMapAndListCollections(){val map=buildJsonObject{put("2",buildJsonObject{put("name","two")})};assertEquals("2",collection(map,listOf("id")).single().first);val list=buildJsonArray{add(buildJsonObject{put("episode_number",3)})};assertEquals("3",collection(list,listOf("episode_number")).single().first)}
    @Test fun jsStyleQueryIsUtf8(){assertEquals("type=tv&title=%D0%94%D0%BE%D0%BC%20TV",query(linkedMapOf("type" to "tv","title" to "Дом TV")))}
    @Test fun findsHlsBeforeMp4(){val root=buildJsonObject{put("video",buildJsonObject{put("file","https://x/video.mp4");put("master","https://x/master.m3u8")})};assertTrue(streamUrls(root).first().endsWith(".m3u8"))}
}
