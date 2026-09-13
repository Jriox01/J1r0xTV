package tv.j1r0x.app.data.repository

import kotlinx.coroutines.flow.Flow
import tv.j1r0x.app.data.database.*
import tv.j1r0x.app.domain.model.MediaItem

class LibraryRepository(private val db:J1r0xDatabase){
    val favorites=db.favorites().observeAll(); val history=db.history().observeAll()
    fun isFavorite(id:String,type:String)=db.favorites().observeExists(id,type)
    suspend fun toggle(item:MediaItem,current:Boolean){if(current)db.favorites().delete(item.id,item.type) else db.favorites().upsert(FavoriteEntity(item.id,item.type,item.title,item.originalTitle,item.poster,item.backdrop,item.year,item.rating,item.raw.toString()))}
    suspend fun started(
        item:MediaItem,
        source:String,
        translation:String,
        season:String,
        episode:String,
        providerId:String="atodo",
        providerMediaId:String=item.id,
        translationId:String="",
        positionMs:Long=0,
    )=db.history().upsert(
        WatchHistoryEntity(
            mediaId=item.id,
            mediaType=item.type,
            title=item.title,
            originalTitle=item.originalTitle,
            poster=item.poster,
            backdrop=item.backdrop,
            year=item.year,
            rating=item.rating,
            rawJson=item.raw.toString(),
            providerId=providerId,
            providerMediaId=providerMediaId,
            sourceId=source,
            translationId=translationId,
            translationName=translation,
            season=season,
            episode=episode,
            positionMs=positionMs.coerceAtLeast(0),
        ),
    )
    suspend fun progress(entry:WatchHistoryEntity,position:Long,duration:Long){val ratio=if(duration>0)position.toDouble()/duration else 0.0;if(duration>0&&ratio>=.9)db.history().delete(entry.mediaId,entry.mediaType,entry.season,entry.episode)else db.history().upsert(entry.copy(positionMs=position.coerceAtLeast(0),durationMs=duration.coerceAtLeast(0),progress=ratio.coerceAtLeast(0.0),updatedAt=System.currentTimeMillis()))}
    suspend fun clearHistory()=db.history().clear()
}
