package tv.j1r0x.app.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(entities=[FavoriteEntity::class,WatchHistoryEntity::class],version=2,exportSchema=false)
abstract class J1r0xDatabase:RoomDatabase(){abstract fun favorites():FavoritesDao;abstract fun history():WatchHistoryDao}

val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL(
            "ALTER TABLE watch_history ADD COLUMN providerId TEXT NOT NULL DEFAULT 'atodo'",
        )
        database.execSQL(
            "ALTER TABLE watch_history ADD COLUMN providerMediaId TEXT NOT NULL DEFAULT ''",
        )
        database.execSQL(
            "ALTER TABLE watch_history ADD COLUMN translationId TEXT NOT NULL DEFAULT ''",
        )
        database.execSQL(
            "UPDATE watch_history SET providerMediaId = mediaId WHERE providerMediaId = ''",
        )
    }
}
