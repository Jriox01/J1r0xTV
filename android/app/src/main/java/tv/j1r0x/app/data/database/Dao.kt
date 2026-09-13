package tv.j1r0x.app.data.database

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao interface FavoritesDao {
    @Query("SELECT * FROM favorites ORDER BY addedAt DESC") fun observeAll():Flow<List<FavoriteEntity>>
    @Query("SELECT EXISTS(SELECT 1 FROM favorites WHERE mediaId=:id AND mediaType=:type)") fun observeExists(id:String,type:String):Flow<Boolean>
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun upsert(value:FavoriteEntity)
    @Query("DELETE FROM favorites WHERE mediaId=:id AND mediaType=:type") suspend fun delete(id:String,type:String)
}
@Dao interface WatchHistoryDao {
    @Query("SELECT * FROM watch_history WHERE progress < 0.9 ORDER BY updatedAt DESC") fun observeAll():Flow<List<WatchHistoryEntity>>
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun upsert(value:WatchHistoryEntity)
    @Query("DELETE FROM watch_history WHERE mediaId=:id AND mediaType=:type AND season=:season AND episode=:episode") suspend fun delete(id:String,type:String,season:String="",episode:String="")
    @Query("DELETE FROM watch_history") suspend fun clear()
}
