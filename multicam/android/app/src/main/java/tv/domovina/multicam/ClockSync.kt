package tv.domovina.multicam

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Jedan `time` uzorak: t1/t4 su `SystemClock.elapsedRealtimeNanos()` pri slanju i
 * primitku, `s` je sat relaya (ms) negdje između.
 */
data class ClockSample(val t1: Long, val t4: Long, val s: Long) {
    val rttNs get() = t4 - t1
    val midNs get() = (t1 + t4) / 2
    fun toJson(): JSONObject = JSONObject().put("t1", t1).put("t4", t4).put("s", s)
}

/**
 * Svi uzorci sata, na disku (append-only, jedna datoteka po paljenju telefona jer se
 * elapsedRealtime resetira pri bootu) i zadnjih nekoliko u memoriji za procjenu.
 *
 * Sidecar takea dobije sve uzorke od ≥10 min prije snimke do kraja uploada, pa i one
 * iz prethodnih pokretanja aplikacije — zato disk, ne memorija.
 */
class ClockSync(context: Context) {
    private val dir = File(context.filesDir, "clock").apply { mkdirs() }
    val boot: Int = try {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
    } catch (e: Exception) {
        -1
    }
    private val file = fileFor(boot)
    private val recent = ArrayDeque<ClockSample>()

    init {
        // Stari bootovi: elapsedRealtime im više ne znači ništa; čuvaj ih tjedan dana.
        val weekAgo = System.currentTimeMillis() - 7 * 86_400_000L
        dir.listFiles()?.filter { it != file && it.lastModified() < weekAgo }?.forEach { it.delete() }
        // Nakon restarta aplikacije procjena smije krenuti od uzoraka s diska.
        val now = SystemClock.elapsedRealtimeNanos()
        read(boot, now - RECENT_WINDOW_NS, now).forEach { recent.addLast(it) }
    }

    fun fileFor(boot: Int) = File(dir, "samples-boot$boot.txt")

    @Synchronized
    fun add(sample: ClockSample) {
        try {
            file.appendText("${sample.t1} ${sample.t4} ${sample.s}\n")
        } catch (e: Exception) {
            Log.w(RelayClient.TAG, "clock: zapis uzorka nije uspio: ${e.message}")
        }
        recent.addLast(sample)
        val cutoff = sample.t4 - RECENT_WINDOW_NS
        while (recent.isNotEmpty() && recent.first().t4 < cutoff) recent.removeFirst()
    }

    /** Uzorci s `t4` u [fromNs, toNs] iz datoteke zadanog boota. */
    fun read(boot: Int, fromNs: Long, toNs: Long): List<ClockSample> {
        val f = fileFor(boot)
        if (!f.exists()) return emptyList()
        return synchronized(this) { f.readLines() }.mapNotNull { line ->
            val p = line.trim().split(' ')
            if (p.size != 3) return@mapNotNull null
            val s = ClockSample(p[0].toLongOrNull() ?: return@mapNotNull null, p[1].toLongOrNull() ?: return@mapNotNull null, p[2].toLongOrNull() ?: return@mapNotNull null)
            s.takeIf { it.t4 in fromNs..toNs && it.t4 >= it.t1 }
        }
    }

    fun samplesJson(boot: Int, fromNs: Long, toNs: Long): JSONArray = JSONArray().apply { read(boot, fromNs, toNs).forEach { put(it.toJson()) } }

    /** Uzorak s najkraćim RTT-om među nedavnima (zadnjih [maxAgeNs]). */
    @Synchronized
    fun best(maxAgeNs: Long = RECENT_WINDOW_NS): ClockSample? {
        val cutoff = SystemClock.elapsedRealtimeNanos() - maxAgeNs
        return recent.filter { it.t4 >= cutoff }.minByOrNull { it.rttNs }
    }

    @Synchronized
    fun newest(): ClockSample? = recent.lastOrNull()

    /**
     * Sat relaya (ms, s decimalama) u trenutku `deviceNs` po najboljem nedavnom uzorku:
     * s je izmjeren u sredini puta, (t1+t4)/2. Drift se zanemaruje (minute, ne sati).
     */
    fun serverMsAt(deviceNs: Long, maxAgeNs: Long = RECENT_WINDOW_NS): Double? {
        val b = best(maxAgeNs) ?: return null
        return b.s + (deviceNs - b.midNs) / 1e6
    }

    /** elapsedRealtimeNanos u kojem će sat relaya pokazati `serverMs`. */
    fun deviceNsAt(serverMs: Long, maxAgeNs: Long = RECENT_WINDOW_NS): Long? {
        val b = best(maxAgeNs) ?: return null
        return b.midNs + ((serverMs - b.s) * 1_000_000L)
    }

    companion object {
        /** Procjena za raspored uzima uzorke iz zadnjih 5 min (≈60 uzoraka). */
        const val RECENT_WINDOW_NS = 5 * 60 * 1_000_000_000L
    }
}
