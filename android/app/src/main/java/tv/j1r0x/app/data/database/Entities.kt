package tv.j1r0x.app.data.database

import androidx.room.ColumnInfo
import androidx.room.Entity

@Entity(tableName="favorites", primaryKeys=["mediaId","mediaType"])
data class FavoriteEntity(val mediaId:String,val mediaType:String,val title:String,val originalTitle:String="",val poster:String="",val backdrop:String="",val year:String="",val rating:String="",val rawJson:String="{}",val addedAt:Long=System.currentTimeMillis())

@Entity(tableName="watch_history", primaryKeys=["mediaId","mediaType","season","episode"])
data class WatchHistoryEntity(
    val mediaId:String,
    val mediaType:String,
    val title:String,
    val originalTitle:String="",
    val poster:String="",
    val backdrop:String="",
    val year:String="",
    val rating:String="",
    val rawJson:String="{}",
    @ColumnInfo(defaultValue="'atodo'") val providerId:String="atodo",
    @ColumnInfo(defaultValue="''") val providerMediaId:String="",
    val sourceId:String="",
    @ColumnInfo(defaultValue="''") val translationId:String="",
    @ColumnInfo(name="translation") val translationName:String="",
    val season:String="",
    val episode:String="",
    val positionMs:Long=0,
    val durationMs:Long=0,
    val progress:Double=0.0,
    val updatedAt:Long=System.currentTimeMillis(),
)
