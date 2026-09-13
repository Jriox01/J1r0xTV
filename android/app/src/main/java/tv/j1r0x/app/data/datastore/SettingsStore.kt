package tv.j1r0x.app.data.datastore

import android.content.Context
import androidx.datastore.preferences.core.*
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.map

private val Context.settings by preferencesDataStore("settings")
class SettingsStore(private val context:Context){
    private val section=stringPreferencesKey("last_section")
    val lastSection=context.settings.data.map{it[section]?:"movies"}
    suspend fun setLastSection(value:String){context.settings.edit{it[section]=value}}
}
