package tv.domovina.multicam

import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * WebSocket prema relayu (role=camera). Sam se ponovno spaja (1→10 s), a pri svakom
 * spajanju izmjeri pomak sata prema relayu. Svi callbackovi stižu na glavnu nit.
 */
class RelayClient(
    private val config: RelayConfig,
    private val deviceId: String,
    private val onOpen: () -> Unit,
    private val onMessage: (JSONObject) -> Unit,
    private val onConnectionChange: (Boolean) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder()
        .pingInterval(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private var socket: WebSocket? = null
    private var closed = false
    private var backoffMs = 1000L

    /** s − (c + rtt/2) iz najkraćeg od pet mjerenja; null dok se ne izmjeri. */
    var serverOffsetMs: Long? = null
        private set
    private var bestRtt = Long.MAX_VALUE
    private var timeRounds = 0

    var connected = false
        private set

    fun start() {
        closed = false
        connect()
    }

    fun close() {
        closed = true
        main.removeCallbacksAndMessages(null)
        socket?.close(1000, "bye")
        socket = null
    }

    fun send(msg: JSONObject): Boolean = socket?.takeIf { connected }?.send(msg.toString()) ?: false

    private fun connect() {
        val url = config.wsUrl + "?role=camera&id=" + deviceId + "&key=" + android.net.Uri.encode(config.key)
        val request = Request.Builder().url(url).build()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = main.post {
                if (webSocket !== socket) return@post
                connected = true
                backoffMs = 1000
                bestRtt = Long.MAX_VALUE
                timeRounds = 0
                onConnectionChange(true)
                onOpen()
                sendTime()
            }.let {}

            override fun onMessage(webSocket: WebSocket, text: String) = main.post {
                if (webSocket !== socket) return@post
                val msg = try { JSONObject(text) } catch (e: Exception) { return@post }
                if (msg.optString("type") == "time") handleTime(msg) else onMessage(msg)
            }.let {}

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
        onConnectionChange(false)
        if (closed) return
        main.postDelayed({ if (!closed && socket == null) connect() }, backoffMs)
        backoffMs = (backoffMs * 2).coerceAtMost(10_000)
    }

    private fun sendTime() {
        send(JSONObject().put("type", "time").put("c", System.currentTimeMillis()))
    }

    private fun handleTime(msg: JSONObject) {
        val now = System.currentTimeMillis()
        val c = msg.optLong("c")
        val s = msg.optLong("s")
        val rtt = now - c
        if (rtt in 0 until bestRtt) {
            bestRtt = rtt
            serverOffsetMs = s - (c + rtt / 2)
        }
        timeRounds++
        if (timeRounds < 5) sendTime() else Log.i(TAG, "time sync: offset=${serverOffsetMs} ms, rtt=$bestRtt ms")
    }

    companion object { const val TAG = "Multicam" }
}
