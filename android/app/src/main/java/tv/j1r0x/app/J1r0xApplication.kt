package tv.j1r0x.app

import android.app.Application
import android.os.Build
import android.util.Log
import androidx.room.Room
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import tv.j1r0x.app.data.database.J1r0xDatabase
import tv.j1r0x.app.data.database.MIGRATION_1_2
import tv.j1r0x.app.data.datastore.SettingsStore
import tv.j1r0x.app.data.provider.ProviderLogger
import tv.j1r0x.app.data.provider.ProviderManager
import tv.j1r0x.app.data.provider.atodo.AtodoProvider
import tv.j1r0x.app.data.provider.buildVariantProviders
import tv.j1r0x.app.data.provider.rezka.RezkaConfig
import tv.j1r0x.app.data.provider.rezka.RezkaProvider
import tv.j1r0x.app.data.repository.LibraryRepository
import tv.j1r0x.app.data.repository.MediaRepository

class J1r0xApplication:Application(),ImageLoaderFactory{
    lateinit var database:J1r0xDatabase; lateinit var settings:SettingsStore
    val media by lazy{MediaRepository()}; lateinit var library:LibraryRepository
    val rezkaConfig by lazy { RezkaConfig.fromBuildConfig() }
    private val atodoProvider by lazy { AtodoProvider(media) }
    private val rezkaProvider by lazy { RezkaProvider(rezkaConfig) }
    val providerManager by lazy {
        ProviderManager(
            providers = listOf(atodoProvider) + buildVariantProviders(rezkaProvider),
            logger = ProviderLogger { message ->
                if (BuildConfig.DEBUG) Log.d("J1r0xProvider", message)
            },
        )
    }
    override fun onCreate(){super.onCreate();settings=SettingsStore(this);database=Room.databaseBuilder(this,J1r0xDatabase::class.java,"j1r0xtv.db").addMigrations(MIGRATION_1_2).build();library=LibraryRepository(database)}
    override fun newImageLoader()=ImageLoader.Builder(this).components{if(Build.VERSION.SDK_INT>=28)add(ImageDecoderDecoder.Factory())else add(GifDecoder.Factory())}.crossfade(true).respectCacheHeaders(false).build()
}
