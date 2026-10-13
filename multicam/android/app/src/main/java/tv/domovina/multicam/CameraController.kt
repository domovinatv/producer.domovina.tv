package tv.domovina.multicam

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Log
import android.util.Range
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class CamState(val wire: String) { IDLE("idle"), RECORDING("recording"), UPLOADING("uploading"), ERROR("error") }

/**
 * Sve što aplikacija radi: kamera, snimanje, relay i upload. UI samo čita stanje.
 *
 * Snimka je jedna mp4 datoteka sa slikom i zvukom iz mikrofona telefona — isti
 * sat uređaja, pa post može poravnati kameru korelacijom njenog zvuka s miksom.
 */
class CameraController(private val context: Context) {
    val config = Config(context)
    private val main = Handler(Looper.getMainLooper())
    val recordDir: File = File(context.getExternalFilesDir(null), "takes").apply { mkdirs() }

    // --- stanje za UI ---
    var connected by mutableStateOf(false); private set
    var state by mutableStateOf(CamState.IDLE); private set
    var recordingSeconds by mutableStateOf(0.0); private set
    var uploadProgress by mutableStateOf<Pair<Long, Long>?>(null); private set
    var lastError by mutableStateOf<String?>(null); private set
    var cameraName by mutableStateOf(config.name); private set
    var room by mutableStateOf(config.relay?.room); private set
    var fpsInfo by mutableStateOf<String?>(null); private set

    private var relay: RelayClient? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var current: Take? = null
    /** `start` koji je stigao prije nego što je kamera spremna. */
    private var pendingStart: Pair<String, String>? = null

    private data class Take(val sessionId: String, val takeId: String, val file: File, var wallClockMs: Long? = null, var serverOffsetMs: Long? = null)

    private val uploader: Uploader = Uploader(
        File(context.filesDir, "pending"),
        configProvider = { config.relay },
        onProgress = { done, total -> main.post { uploadProgress = done to total; if (state != CamState.RECORDING) transition(CamState.UPLOADING) } },
        onDone = { sid, tid, keys ->
            main.post {
                relay?.send(JSONObject().put("type", "uploaded").put("sessionId", sid).put("takeId", tid).put("objectKeys", org.json.JSONArray(keys)))
                if (!uploader.hasPending()) {
                    uploadProgress = null
                    if (state == CamState.UPLOADING) transition(CamState.IDLE)
                }
            }
        },
        onError = { e -> main.post { if (e != null || lastError?.startsWith("Upload") == true) { lastError = e; sendStatus() } } },
    )

    private val ticker = object : Runnable {
        override fun run() {
            sendStatus()
            main.postDelayed(this, 2000)
        }
    }

    init {
        main.post(ticker)
        uploader.kick()
    }

    // --- relay ---

    fun connect() {
        cameraName = config.name
        relay?.close()
        val cfg = config.relay ?: run { relay = null; connected = false; return }
        room = cfg.room
        relay = RelayClient(cfg, config.deviceId,
            onOpen = { sendHello(); sendStatus() },
            onMessage = ::handle,
            onConnectionChange = { connected = it },
        ).also { it.start() }
    }

    fun rename(name: String) {
        config.name = name
        cameraName = config.name
        sendHello()
    }

    private fun sendHello() {
        relay?.send(
            JSONObject().put("type", "hello").put("id", config.deviceId).put("name", config.name)
                .put("platform", "android").put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("os", Build.VERSION.RELEASE).put("app", "0.1"),
        )
    }

    private fun handle(msg: JSONObject) {
        when (msg.optString("type")) {
            "start" -> startTake(msg.getString("sessionId"), msg.getString("takeId"))
            "stop" -> stopTake()
        }
    }

    private fun sendStatus() {
        val r = relay ?: return
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val msg = JSONObject().put("type", "status").put("state", state.wire)
            .put("battery", if (level >= 0) level.toDouble() / scale else JSONObject.NULL)
            .put("charging", plugged)
            .put("freeBytes", StatFs(recordDir.path).availableBytes)
        current?.let { msg.put("takeId", it.takeId) }
        if (state == CamState.RECORDING) msg.put("recordingSeconds", recordingSeconds)
        uploadProgress?.let { (d, t) -> msg.put("upload", JSONObject().put("bytesDone", d).put("bytesTotal", t)) }
        lastError?.let { msg.put("error", it) }
        r.send(msg)
    }

    private fun transition(s: CamState) {
        if (state == s) return
        state = s
        sendStatus()
    }

    // --- kamera ---

    fun bind(owner: LifecycleOwner, previewView: PreviewView) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val provider = future.get()
            val selector = CameraSelector.DEFAULT_BACK_CAMERA
            val fps = Range(30, 30)
            val info = provider.getCameraInfo(selector)
            val supported = info.supportedFrameRateRanges
            val fixed30 = supported.contains(fps)
            Log.i(RelayClient.TAG, "podržani fps rasponi: $supported")
            fpsInfo = if (fixed30) null else "Kamera ne nudi fiksnih 30 fps: $supported"

            val recorder = Recorder.Builder()
                .setQualitySelector(QualitySelector.from(Quality.FHD, FallbackStrategy.lowerQualityOrHigherThan(Quality.FHD)))
                .setTargetVideoEncodingBitRate(16_000_000)
                .build()
            val vc = VideoCapture.Builder(recorder)
                .setTargetFrameRate(fps)
                .setVideoStabilizationEnabled(false)
                .build()
            val preview = Preview.Builder()
                .setTargetFrameRate(fps)
                .setPreviewStabilizationEnabled(false)
                .build()
                .also { it.surfaceProvider = previewView.surfaceProvider }
            try {
                provider.unbindAll()
                provider.bindToLifecycle(owner, selector, preview, vc)
                videoCapture = vc
                pendingStart?.let { (s, t) -> pendingStart = null; startTake(s, t) }
            } catch (e: Exception) {
                Log.e(RelayClient.TAG, "bind kamere", e)
                lastError = "Kamera: ${e.message}"
                transition(CamState.ERROR)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun toggleManual() {
        if (recording != null) stopTake()
        else {
            val id = "local-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
            startTake(id, id)
        }
    }

    @SuppressLint("MissingPermission")
    fun startTake(sessionId: String, takeId: String) {
        current?.let { if (it.takeId == takeId && recording != null) return }
        if (recording != null) {
            // Drugi take dok ovaj traje: prvo zatvori stari, novi kreće iz Finalize.
            pendingStart = sessionId to takeId
            stopTake()
            return
        }
        val vc = videoCapture ?: run { pendingStart = sessionId to takeId; return }
        val ext = "mp4"
        val file = File(recordDir, "${safe(takeId)}.$ext").let { f ->
            if (!f.exists()) f else File(recordDir, "${safe(takeId)}-${System.currentTimeMillis()}.$ext")
        }
        val take = Take(sessionId, takeId, file)
        current = take
        lastError = null
        recordingSeconds = 0.0
        recording = vc.output.prepareRecording(context, FileOutputOptions.Builder(file).build())
            .withAudioEnabled()
            .start(ContextCompat.getMainExecutor(context)) { e -> onRecordEvent(take, e) }
        transition(CamState.RECORDING)
    }

    fun shutdown() {
        stopTake()
        relay?.close()
        main.removeCallbacks(ticker)
    }

    fun stopTake() {
        recording?.stop()
        recording = null
    }

    private fun onRecordEvent(take: Take, e: VideoRecordEvent) {
        when (e) {
            is VideoRecordEvent.Start -> {
                // Trenutak kad Recorder javi da je snimanje krenulo — grubo (±50 ms)
                // vrijeme prvog framea; post ga koristi samo za sužavanje pretrage.
                take.wallClockMs = System.currentTimeMillis()
                take.serverOffsetMs = relay?.serverOffsetMs
                relay?.send(
                    JSONObject().put("type", "recordingStarted").put("sessionId", take.sessionId).put("takeId", take.takeId)
                        .put("file", take.file.name).put("wallClockMs", take.wallClockMs),
                )
            }
            is VideoRecordEvent.Status -> recordingSeconds = e.recordingStats.recordedDurationNanos / 1e9
            is VideoRecordEvent.Finalize -> {
                if (current === take) current = null
                recording = null
                val duration = e.recordingStats.recordedDurationNanos / 1e9
                if (e.hasError()) {
                    Log.e(RelayClient.TAG, "Finalize greška ${e.error}", e.cause)
                    lastError = "Snimanje: greška ${e.error} ${e.cause?.message ?: ""}"
                }
                if (take.file.exists() && take.file.length() > 0) {
                    val sidecar = writeSidecar(take, duration)
                    relay?.send(
                        JSONObject().put("type", "recordingStopped").put("sessionId", take.sessionId).put("takeId", take.takeId)
                            .put("file", take.file.name).put("durationSeconds", duration).put("bytes", take.file.length()),
                    )
                    Log.i(RelayClient.TAG, "snimka: ${take.file.absolutePath} (${take.file.length()} B, $duration s)")
                    transition(CamState.UPLOADING)
                    uploadProgress = 0L to take.file.length()
                    uploader.enqueue(take.sessionId, take.takeId, config.name, take.file, sidecar)
                } else {
                    transition(if (lastError != null) CamState.ERROR else CamState.IDLE)
                }
                pendingStart?.let { (s, t) -> pendingStart = null; startTake(s, t) }
            }
            else -> {}
        }
    }

    private fun writeSidecar(take: Take, duration: Double): File {
        val video = JSONObject()
        val audio = JSONObject()
        try {
            val ex = MediaExtractor()
            ex.setDataSource(take.file.path)
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    video.put("width", f.getInteger(MediaFormat.KEY_WIDTH)).put("height", f.getInteger(MediaFormat.KEY_HEIGHT))
                    video.put("fps", if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) f.getNumber(MediaFormat.KEY_FRAME_RATE) else 30)
                    video.put("codec", when (mime) { "video/avc" -> "h264"; "video/hevc" -> "hevc"; else -> mime })
                } else if (mime.startsWith("audio/")) {
                    audio.put("sampleRate", f.getInteger(MediaFormat.KEY_SAMPLE_RATE)).put("channels", f.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                }
            }
            ex.release()
        } catch (e: Exception) {
            Log.w(RelayClient.TAG, "MediaExtractor: ${e.message}")
        }
        val json = JSONObject()
            .put("version", 1).put("sessionId", take.sessionId).put("takeId", take.takeId)
            .put("camera", JSONObject().put("id", config.deviceId).put("name", config.name).put("platform", "android")
                .put("model", "${Build.MANUFACTURER} ${Build.MODEL}").put("os", Build.VERSION.RELEASE))
            .put("file", take.file.name)
            .put("video", video).put("audio", audio)
            .put("startWallClockMs", take.wallClockMs ?: JSONObject.NULL)
            .put("serverOffsetMs", take.serverOffsetMs ?: JSONObject.NULL)
            .put("durationSeconds", duration)
        return File(recordDir, take.file.nameWithoutExtension + ".json").apply { writeText(json.toString(2)) }
    }

    private fun safe(s: String) = s.replace(Regex("[^\\w.-]+"), "-")
}
