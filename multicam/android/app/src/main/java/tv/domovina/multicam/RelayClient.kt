package tv.domovina.multicam

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * WebSocket prema relayu (role=camera). Sam se ponovno spaja (1→10 s). Dok je spojen,
 * mjeri sat prema relayu: pet brzih `time` pri spajanju, zatim jedan svakih 5 s.
 * Svaki odgovor ide u [clock]. Svi callbackovi stižu na glavnu nit.
 *
 * Prekid veze ne utječe na snimanje — ovaj razred ne zna ništa o kameri.
 */
class RelayClient(
    private val config: RelayConfig,
    private val deviceId: String,
    private val clock: ClockSync,
    private val onOpen: () -> Unit,
    private val onMessage: (JSONObject) -> Unit,
    private val onConnectionChange: (Boolean) -> Unit,
    private val onClockSample: (ClockSample) -> Unit = {},
) {
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder()
        .pingInterval(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    @Volatile private var socket: WebSocket? = null
    private var closed = false
    private var backoffMs = 1000L

    /** c (ms, jedinstven) → t1 (elapsedRealtimeNanos) za `time` koji čekaju odgovor. */
    private val inFlight = ConcurrentHashMap<Long, Long>()
    private var lastC = 0L
    private var burstLeft = 0

    /** Događaji takea (recordingStarted/Stopped/uploaded) koji nisu otišli jer veze nije bilo. */
    private val outbox = ArrayDeque<JSONObject>()

    var connected = false
        private set

    private val timeTicker = object : Runnable {
        override fun run() {
            if (connected) sendTime()
            main.postDelayed(this, TIME_INTERVAL_MS)
        }
    }

    /** Stari pomak (ms) za v1 polje `serverOffsetMs`: server − wall clock, iz najboljeg uzorka. */
    val serverOffsetMs: Long?
        get() {
            val nowNs = SystemClock.elapsedRealtimeNanos()
            val wall = System.currentTimeMillis()
            return clock.serverMsAt(nowNs)?.let { Math.round(it - wall) }
        }

    fun start() {
        closed = false
        connect()
        main.postDelayed(timeTicker, TIME_INTERVAL_MS)
    }

    fun close() {
        closed = true
        main.removeCallbacksAndMessages(null)
        socket?.close(1000, "bye")
        socket = null
        connected = false
    }

    fun send(msg: JSONObject): Boolean = socket?.takeIf { connected }?.send(msg.toString()) ?: false

    /** Šalje sad ako je spojen, inače čim se spoji (redom). */
    fun sendReliable(msg: JSONObject) {
        if (outbox.isEmpty() && send(msg)) return
        outbox.addLast(msg)
        if (outbox.size > 100) outbox.removeFirst()
    }

    private fun connect() {
        val url = config.wsUrl + "?role=camera&id=" + deviceId + "&key=" + android.net.Uri.encode(config.key)
        val request = Request.Builder().url(url).build()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = main.post {
                if (webSocket !== socket) return@post
                connected = true
                backoffMs = 1000
                onConnectionChange(true)
                onOpen()
                while (outbox.isNotEmpty() && send(outbox.first())) outbox.removeFirst()
                inFlight.clear()
                burstLeft = BURST
                sendTime()
            }.let {}

            override fun onMessage(webSocket: WebSocket, text: String) {
                // t4 odmah na niti čitača, prije prebacivanja na glavnu nit.
                val t4 = SystemClock.elapsedRealtimeNanos()
                main.post {
                    if (webSocket !== socket) return@post
                    val msg = try { JSONObject(text) } catch (e: Exception) { return@post }
                    if (msg.optString("type") == "time") handleTime(msg, t4) else onMessage(msg)
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = main.post { dropped(webSocket, "closed $code $reason") }.let {}

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                main.post { dropped(webSocket, "failure ${t.message} ${response?.code ?: ""}") }.let {}
        })
    }

    private fun dropped(webSocket: WebSocket, why: String) {
        if (webSocket !== socket) return
        Log.w(TAG, "relay: $why")
        connected = false
        socket = null
        inFlight.clear()
        onConnectionChange(false)
        if (closed) return
        main.postDelayed({ if (!closed && socket == null) connect() }, backoffMs)
        backoffMs = (backoffMs * 2).coerceAtMost(10_000)
    }

    private fun sendTime() {
        val ws = socket?.takeIf { connected } ?: return
        var c = System.currentTimeMillis()
        if (c <= lastC) c = lastC + 1
        lastC = c
        if (inFlight.size > 50) inFlight.clear()
        val payload = JSONObject().put("type", "time").put("c", c).toString()
        val t1 = SystemClock.elapsedRealtimeNanos()
        inFlight[c] = t1
        ws.send(payload)
    }

    private fun handleTime(msg: JSONObject, t4: Long) {
        val c = msg.optLong("c")
        val t1 = inFlight.remove(c) ?: return
        if (!msg.has("s")) return
        val sample = ClockSample(t1, t4, msg.getLong("s"))
        clock.add(sample)
        onClockSample(sample)
        if (burstLeft > 0) {
            burstLeft--
            if (burstLeft > 0) sendTime()
            else clock.best()?.let { Log.i(TAG, "time sync: najbolji RTT ${"%.1f".format(it.rttNs / 1e6)} ms") }
        }
    }

    companion object {
        const val TAG = "Multicam"
        const val TIME_INTERVAL_MS = 5000L
        const val BURST = 5
    }
}
