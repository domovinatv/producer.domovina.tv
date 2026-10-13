package tv.domovina.multicam

import android.annotation.SuppressLint
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
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
import android.os.SystemClock
import android.util.Log
import android.util.Range
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
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
    /** "Snimanje kreće za …" dok čeka zakazani start. */
    var scheduledInfo by mutableStateOf<String?>(null); private set
    /** Zadnji uzorak sata, za prikaz. */
    var clockInfo by mutableStateOf<String?>(null); private set

    val clock = ClockSync(context)
    private val prefs = context.getSharedPreferences("multicam", Context.MODE_PRIVATE)

    private var relay: RelayClient? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var current: Take? = null
    /** `start` koji je stigao prije nego što je kamera spremna (ili dok se stari take zatvara). */
    private var pendingStart: PendingStart? = null
    /** `start` koji čeka svoj `startAtServerMs`. */
    private var scheduled: PendingStart? = null
    private var scheduledRunnable: Runnable? = null

    private data class PendingStart(val sessionId: String, val takeId: String, val relay: Boolean, val startAtServerMs: Long? = null)

    private class Take(val sessionId: String, val takeId: String, val file: File, val relay: Boolean, val startAtServerMs: Long?) {
        var wallClockMs: Long? = null
        var serverOffsetMs: Long? = null
        /** elapsedRealtimeNanos u kojem je pozvan `Recording.start`. */
        var startCallNs: Long = 0
        var fileZeroDeviceNs: Long? = null
        var fileZeroMethod: String = "unknown"
        var fileZeroUncertaintyMs: Double? = null
        /** Rezerva: min(vrijeme Status događaja − recordedDuration) — gornja granica prvog framea. */
        var statusBoundNs: Long = Long.MAX_VALUE
        var statusEvents = 0
    }

    // --- vrijeme prvog framea ---

    /** Zadnjih ~17 s senzorskih vremena (Camera2 SENSOR_TIMESTAMP) za provjeru fileZero. */
    private val sensorTs = LongArray(512)
    private var sensorTsCount = 0L
    private var timestampSource: String = "?"
    private val firstVideoField by lazy {
        try {
            Recorder::class.java.getDeclaredField("mFirstRecordingVideoDataTimeUs").apply { isAccessible = true }
        } catch (e: Exception) {
            Log.w(RelayClient.TAG, "Recorder.mFirstRecordingVideoDataTimeUs nedostupan: ${e.message}")
            null
        }
    }

    private val uploader: Uploader = Uploader(
        File(context.filesDir, "pending"),
        configProvider = { config.relay },
        onProgress = { done, total -> main.post { uploadProgress = done to total; if (state != CamState.RECORDING) transition(CamState.UPLOADING) } },
        onDone = { sid, tid, keys ->
            main.post {
                relay?.sendReliable(JSONObject().put("type", "uploaded").put("sessionId", sid).put("takeId", tid).put("objectKeys", org.json.JSONArray(keys)))
                if (!uploader.hasPending()) {
                    uploadProgress = null
                    if (state == CamState.UPLOADING) transition(CamState.IDLE)
                }
            }
        },
        onError = { e -> main.post { if (e != null || lastError?.startsWith("Upload") == true) { lastError = e; sendStatus() } } },
        refreshSidecar = { job, f -> refreshSidecar(job, f) },
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
        relay = RelayClient(cfg, config.deviceId, clock,
            onOpen = { sendHello(); sendStatus() },
            onMessage = ::handle,
            onConnectionChange = { connected = it },
            onClockSample = ::onClockSample,
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
            "start" -> scheduleStart(
                PendingStart(msg.getString("sessionId"), msg.getString("takeId"), relay = true,
                    startAtServerMs = if (msg.has("startAtServerMs")) msg.getLong("startAtServerMs") else null),
            )
            "stop" -> {
                val takeId = msg.optString("takeId")
                if (takeId.isBlank() || scheduled?.takeId == takeId) cancelScheduled()
                if (takeId.isBlank() || pendingStart?.takeId == takeId) pendingStart = null
                if (takeId.isBlank() || current?.takeId == takeId) stopTake()
            }
            "state" -> {
                // Stanje relaya pri svakom spajanju: ako snimam take koji više nije
                // aktivan (stop je stigao dok sam bio offline), zaustavi ga.
                val active = msg.optJSONObject("take")?.optString("takeId")
                if (scheduled != null && scheduled?.takeId != active) cancelScheduled()
                if (pendingStart?.relay == true && pendingStart?.takeId != active) pendingStart = null
                val cur = current
                if (cur != null && cur.relay && recording != null && cur.takeId != active) {
                    Log.i(RelayClient.TAG, "state: relay više ne snima ${cur.takeId} (aktivan: $active) — zaustavljam")
                    stopTake()
                }
            }
        }
    }

    // --- zakazani start ---

    private var waitingForClock: PendingStart? = null

    private fun onClockSample(sample: ClockSample) {
        clockInfo = "Sat: RTT %.0f ms".format(sample.rttNs / 1e6)
        waitingForClock?.let { waitingForClock = null; main.removeCallbacks(clockTimeout); scheduleStart(it) }
    }

    private val clockTimeout = Runnable {
        // Nema uzorka sata ni nakon 2 s: kreni odmah, bolje kasno nego nikad.
        waitingForClock?.let { waitingForClock = null; Log.w(RelayClient.TAG, "start bez uzorka sata"); startTake(it) }
    }

    /**
     * Start s `startAtServerMs`: snimanje kreće kad sat relaya (procijenjen iz uzorka
     * s najkraćim RTT-om) dođe do tog trenutka, umanjeno za naučeno kašnjenje
     * CameraX-a od poziva `start` do prvog framea. Ako je trenutak prošao, odmah.
     */
    private fun scheduleStart(p: PendingStart) {
        if (current?.takeId == p.takeId && recording != null) return
        if (scheduled?.takeId == p.takeId || pendingStart?.takeId == p.takeId || waitingForClock?.takeId == p.takeId) return
        cancelScheduled()
        val at = p.startAtServerMs ?: return startTake(p)
        // Treba svjež uzorak (zadnje 2 min); pri spajanju `start` stigne prije prvog `time` odgovora.
        if (clock.best(120_000_000_000L) == null) {
            waitingForClock = p
            main.removeCallbacks(clockTimeout)
            main.postDelayed(clockTimeout, 2000)
            return
        }
        val target = clock.deviceNsAt(at) ?: return startTake(p)
        val delayMs = (target - SystemClock.elapsedRealtimeNanos()) / 1e6 - startLatencyMs
        Log.i(RelayClient.TAG, "start ${p.takeId} @server $at, za %.1f ms (kompenzacija %.0f ms)".format(delayMs, startLatencyMs))
        if (delayMs <= 1) return startTake(p)
        scheduled = p
        val r = Runnable { if (scheduled == p) { scheduled = null; scheduledRunnable = null; scheduledInfo = null; startTake(p) } }
        scheduledRunnable = r
        main.postDelayed(r, delayMs.toLong())
        scheduledInfo = "Snimanje kreće za %.1f s".format(delayMs / 1000)
    }

    private fun cancelScheduled() {
        scheduledRunnable?.let { main.removeCallbacks(it) }
        scheduledRunnable = null
        scheduled = null
        scheduledInfo = null
        waitingForClock = null
        main.removeCallbacks(clockTimeout)
    }

    /** Naučeno kašnjenje od `Recording.start` do prvog framea (ms), pomični prosjek. */
    private var startLatencyMs: Double
        get() = prefs.getFloat("startLatencyMs", 0f).toDouble()
        set(v) = prefs.edit().putFloat("startLatencyMs", v.toFloat()).apply()

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
            val vcBuilder = VideoCapture.Builder(recorder)
                .setTargetFrameRate(fps)
                .setVideoStabilizationEnabled(false)
            attachSensorTimestamps(vcBuilder)
            readTimestampSource(info)
            val vc = vcBuilder.build()
            val preview = Preview.Builder()
                .setTargetFrameRate(fps)
                .setPreviewStabilizationEnabled(false)
                .build()
                .also { it.surfaceProvider = previewView.surfaceProvider }
            try {
                provider.unbindAll()
                provider.bindToLifecycle(owner, selector, preview, vc)
                videoCapture = vc
                pendingStart?.let { pendingStart = null; startTake(it) }
            } catch (e: Exception) {
                Log.e(RelayClient.TAG, "bind kamere", e)
                lastError = "Kamera: ${e.message}"
                transition(CamState.ERROR)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun attachSensorTimestamps(builder: VideoCapture.Builder<Recorder>) {
        Camera2Interop.Extender(builder).setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                val ts = result.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
                synchronized(sensorTs) { sensorTs[(sensorTsCount++ % sensorTs.size).toInt()] = ts }
            }
        })
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun readTimestampSource(info: androidx.camera.core.CameraInfo) {
        timestampSource = try {
            when (Camera2CameraInfo.from(info).getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)) {
                CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "REALTIME"
                CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "UNKNOWN"
                else -> "?"
            }
        } catch (e: Exception) { "?" }
        Log.i(RelayClient.TAG, "SENSOR_INFO_TIMESTAMP_SOURCE=$timestampSource")
    }

    /** Najbliže senzorsko vrijeme framea (Camera2) zadanom trenutku; null ako ih nema. */
    private fun nearestSensorTs(ns: Long): Long? = synchronized(sensorTs) {
        val n = minOf(sensorTsCount, sensorTs.size.toLong()).toInt()
        (0 until n).map { sensorTs[it] }.minByOrNull { kotlin.math.abs(it - ns) }
    }

    /** elapsedRealtimeNanos − System.nanoTime(), izmjereno u „sendviču", najuži od 5. */
    private fun realtimeMinusUptimeNs(): Long {
        var best = Long.MAX_VALUE
        var off = 0L
        repeat(5) {
            val u1 = System.nanoTime()
            val r = SystemClock.elapsedRealtimeNanos()
            val u2 = System.nanoTime()
            if (u2 - u1 < best) { best = u2 - u1; off = r - (u1 + u2) / 2 }
        }
        return off
    }

    /**
     * fileZeroDeviceNs = vrijeme prvog videoframea, koji je u mp4 PTS 0.
     *
     * CameraX Recorder pamti PTS prvog framea u `mFirstRecordingVideoDataTimeUs` (sat
     * System.nanoTime, µs; enkoder ga pretvori iz senzorskog REALTIME vremena fiksnim
     * pomakom) i od njega oduzima sve ostale PTS-ove — to je točno nula datoteke.
     * Pretvaramo ga natrag u elapsedRealtime i provjeravamo uz najbliže senzorsko
     * vrijeme iz Camera2 CaptureCallbacka.
     */
    private fun tryResolveFileZero(take: Take) {
        if (take.fileZeroDeviceNs != null) return
        val rec = videoCapture?.output ?: return
        val firstUs = try { firstVideoField?.getLong(rec) } catch (e: Exception) { null } ?: return
        if (firstUs == Long.MAX_VALUE || firstUs <= 0) return
        val zero = firstUs * 1000 + realtimeMinusUptimeNs()
        val nearest = nearestSensorTs(zero)
        val residualMs = nearest?.let { (zero - it) / 1e6 }
        // PTS je µs; pomak uptime→realtime CameraX mjeri jednom po enkoderu (µs).
        // Ako se poklapa sa senzorskim vremenom framea, nesigurnost je ispod 0,1 ms.
        val snapped = residualMs != null && kotlin.math.abs(residualMs) < 0.5
        take.fileZeroDeviceNs = if (snapped) nearest else zero
        take.fileZeroUncertaintyMs = if (snapped) 0.1 else 2.0
        take.fileZeroMethod = "camerax-first-video-pts: Recorder.mFirstRecordingVideoDataTimeUs (uptime µs) + (elapsedRealtime−uptime); " +
            "SENSOR_INFO_TIMESTAMP_SOURCE=$timestampSource; " +
            (if (residualMs != null) "najbliži Camera2 SENSOR_TIMESTAMP Δ=%.3f ms%s".format(residualMs, if (snapped) " (uzet senzorski)" else "") else "bez senzorske provjere")
        val latencyMs = (take.fileZeroDeviceNs!! - take.startCallNs) / 1e6
        Log.i(RelayClient.TAG, "fileZero ${take.takeId}: ${take.fileZeroDeviceNs} ns, Δsenzor=${residualMs?.let { "%.3f".format(it) }} ms, " +
            "start→prvi frame %.1f ms".format(latencyMs))
        // Nauči kašnjenje za zakazani start (samo razumne vrijednosti).
        if (latencyMs in 0.0..2000.0) {
            val old = startLatencyMs
            startLatencyMs = if (old <= 0.0) latencyMs else old * 0.7 + latencyMs * 0.3
        }
        take.wallClockMs = System.currentTimeMillis() - (SystemClock.elapsedRealtimeNanos() - take.fileZeroDeviceNs!!) / 1_000_000
    }

    fun toggleManual() {
        if (recording != null) stopTake()
        else {
            cancelScheduled()
            val id = "local-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
            startTake(PendingStart(id, id, relay = false))
        }
    }

    @SuppressLint("MissingPermission")
    private fun startTake(p: PendingStart) {
        current?.let { if (it.takeId == p.takeId && recording != null) return }
        if (recording != null) {
            // Drugi take dok ovaj traje: prvo zatvori stari, novi kreće iz Finalize.
            pendingStart = p
            stopTake()
            return
        }
        val vc = videoCapture ?: run { pendingStart = p; return }
        val ext = "mp4"
        val file = File(recordDir, "${safe(p.takeId)}.$ext").let { f ->
            if (!f.exists()) f else File(recordDir, "${safe(p.takeId)}-${System.currentTimeMillis()}.$ext")
        }
        val take = Take(p.sessionId, p.takeId, file, p.relay, p.startAtServerMs)
        current = take
        lastError = null
        recordingSeconds = 0.0
        take.startCallNs = SystemClock.elapsedRealtimeNanos()
        recording = vc.output.prepareRecording(context, FileOutputOptions.Builder(file).build())
            .withAudioEnabled()
            .start(ContextCompat.getMainExecutor(context)) { e -> onRecordEvent(take, e) }
        transition(CamState.RECORDING)
    }

    fun shutdown() {
        cancelScheduled()
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
                // Grubo vrijeme; točno se postavi iz fileZero kad stigne prvi frame.
                take.wallClockMs = System.currentTimeMillis()
                take.serverOffsetMs = relay?.serverOffsetMs
                relay?.sendReliable(
                    JSONObject().put("type", "recordingStarted").put("sessionId", take.sessionId).put("takeId", take.takeId)
                        .put("file", take.file.name).put("wallClockMs", take.wallClockMs),
                )
            }
            is VideoRecordEvent.Status -> {
                val now = SystemClock.elapsedRealtimeNanos()
                val d = e.recordingStats.recordedDurationNanos
                recordingSeconds = d / 1e9
                if (e.recordingStats.numBytesRecorded > 0) {
                    take.statusBoundNs = minOf(take.statusBoundNs, now - d)
                    take.statusEvents++
                }
                tryResolveFileZero(take)
            }
            is VideoRecordEvent.Finalize -> {
                if (current === take) current = null
                recording = null
                val duration = e.recordingStats.recordedDurationNanos / 1e9
                if (e.hasError()) {
                    Log.e(RelayClient.TAG, "Finalize greška ${e.error}", e.cause)
                    lastError = "Snimanje: greška ${e.error} ${e.cause?.message ?: ""}"
                }
                if (take.fileZeroDeviceNs == null && take.statusEvents > 0) {
                    // Rezerva: Status događaj stiže nakon kodiranja, pa je (vrijeme − trajanje)
                    // uvijek ≥ prvi frame; minimum preko svih događaja je najbliži.
                    take.fileZeroDeviceNs = take.statusBoundNs
                    take.fileZeroMethod = "status-min: min(elapsedRealtime pri VideoRecordEvent.Status − recordedDurationNanos), ${take.statusEvents} događaja"
                    take.fileZeroUncertaintyMs = 30.0
                }
                if (take.statusEvents > 0 && take.fileZeroDeviceNs != null) {
                    Log.i(RelayClient.TAG, "fileZero provjera: status-min − fileZero = %.1f ms (${take.statusEvents} Status događaja)"
                        .format((take.statusBoundNs - take.fileZeroDeviceNs!!) / 1e6))
                }
                if (take.file.exists() && take.file.length() > 0) {
                    val sidecar = writeSidecar(take, duration)
                    relay?.sendReliable(
                        JSONObject().put("type", "recordingStopped").put("sessionId", take.sessionId).put("takeId", take.takeId)
                            .put("file", take.file.name).put("durationSeconds", duration).put("bytes", take.file.length()),
                    )
                    Log.i(RelayClient.TAG, "snimka: ${take.file.absolutePath} (${take.file.length()} B, $duration s)")
                    transition(CamState.UPLOADING)
                    uploadProgress = 0L to take.file.length()
                    uploader.enqueue(take.sessionId, take.takeId, config.name, take.file, sidecar, clock.boot)
                } else {
                    transition(if (lastError != null) CamState.ERROR else CamState.IDLE)
                }
                pendingStart?.let { pendingStart = null; startTake(it) }
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
        json.put("version", 2)
        json.put("clock", JSONObject()
            .put("domain", "android-elapsedRealtime")
            .put("fileZeroDeviceNs", take.fileZeroDeviceNs ?: JSONObject.NULL)
            .put("fileZeroMethod", take.fileZeroMethod)
            .put("fileZeroUncertaintyMs", take.fileZeroUncertaintyMs ?: JSONObject.NULL)
            .put("samples", clock.samplesJson(clock.boot, samplesFrom(take), SystemClock.elapsedRealtimeNanos())))
        take.startAtServerMs?.let { json.put("startAtServerMs", it) }
        return File(recordDir, take.file.nameWithoutExtension + ".json").apply { writeText(json.toString(2)) }
    }

    /** Uzorci od 15 min prije početka snimke. */
    private fun samplesFrom(take: Take) = (take.fileZeroDeviceNs ?: take.startCallNs) - SAMPLES_BEFORE_NS

    /** Prije uploada sidecara: svi uzorci do sad (upload može trajati dugo, i preko restarta). */
    private fun refreshSidecar(job: JSONObject, sidecar: File) {
        val json = JSONObject(sidecar.readText())
        val c = json.optJSONObject("clock") ?: return
        val boot = job.optInt("boot", clock.boot)
        val zero = c.optLong("fileZeroDeviceNs", 0L)
        val from = if (zero > 0) zero - SAMPLES_BEFORE_NS else c.optJSONArray("samples")?.optJSONObject(0)?.optLong("t4") ?: 0L
        val to = if (boot == clock.boot) SystemClock.elapsedRealtimeNanos() else Long.MAX_VALUE
        c.put("samples", clock.samplesJson(boot, from, to))
        sidecar.writeText(json.toString(2))
        Log.i(RelayClient.TAG, "sidecar ${sidecar.name}: ${c.getJSONArray("samples").length()} uzoraka sata")
    }

    companion object {
        const val SAMPLES_BEFORE_NS = 15 * 60 * 1_000_000_000L
    }

    private fun safe(s: String) = s.replace(Regex("[^\\w.-]+"), "-")
}
