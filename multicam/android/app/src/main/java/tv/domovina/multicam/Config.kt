package tv.domovina.multicam

import android.content.Context
import android.net.Uri
import android.os.Build
import java.util.UUID

/** Spajanje na relay: dolazi iz `domovinacam://join?...` linka (QR kod) i pamti se. */
data class RelayConfig(val relay: String, val room: String, val key: String) {
    val wsUrl: String
        get() = relay.trimEnd('/').replaceFirst(Regex("^http"), "ws") + "/v1/rooms/" + Uri.encode(room) + "/ws"
    val httpBase: String get() = relay.trimEnd('/')
}

class Config(context: Context) {
    private val prefs = context.getSharedPreferences("multicam", Context.MODE_PRIVATE)

    /** Stabilan identitet uređaja: generira se jednom, relay po njemu zamjenjuje stari socket. */
    val deviceId: String = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("deviceId", it).apply()
    }

    var relay: RelayConfig?
        get() {
            val r = prefs.getString("relay", null) ?: return null
            val room = prefs.getString("room", null) ?: return null
            val key = prefs.getString("key", null) ?: return null
            return RelayConfig(r, room, key)
        }
        set(v) {
            prefs.edit().putString("relay", v?.relay).putString("room", v?.room).putString("key", v?.key).apply()
        }

    var name: String
        get() = prefs.getString("name", null)?.takeIf { it.isNotBlank() } ?: Build.MODEL
        set(v) = prefs.edit().putString("name", v.trim()).apply()

    /** Vraća true ako je link bio valjan i nešto se promijenilo. */
    fun apply(uri: Uri?): Boolean {
        if (uri == null || uri.scheme != "domovinacam" || uri.host != "join") return false
        val relay = uri.getQueryParameter("relay") ?: return false
        val room = uri.getQueryParameter("room") ?: return false
        val key = uri.getQueryParameter("key") ?: return false
        this.relay = RelayConfig(relay, room, key)
        uri.getQueryParameter("name")?.takeIf { it.isNotBlank() }?.let { name = it }
        return true
    }
}
