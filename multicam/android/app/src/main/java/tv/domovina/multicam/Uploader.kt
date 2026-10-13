package tv.domovina.multicam

import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Upload snimki u R2 preko relaya (multipart, dijelovi od `partSize`).
 *
 * Svaki posao je JSON datoteka u `pending/` i ažurira se nakon svakog dijela, pa se
 * nakon pada ili restarta aplikacije nastavlja od zadnjeg potvrđenog dijela.
 * Lokalne snimke se nikad ne brišu.
 */
class Uploader(
    private val pendingDir: File,
    private val configProvider: () -> RelayConfig?,
    private val onProgress: (bytesDone: Long, bytesTotal: Long) -> Unit,
    private val onDone: (sessionId: String, takeId: String, objectKeys: List<String>) -> Unit,
    private val onError: (String?) -> Unit,
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()
    private val json = "application/json".toMediaType()
    private val octet = "application/octet-stream".toMediaType()

    init {
        pendingDir.mkdirs()
    }

    fun enqueue(sessionId: String, takeId: String, camera: String, video: File, sidecar: File) {
        val job = JSONObject()
            .put("sessionId", sessionId).put("takeId", takeId).put("camera", camera)
            .put("video", video.absolutePath).put("sidecar", sidecar.absolutePath)
            .put("parts", JSONArray())
        File(pendingDir, "$takeId.json").writeText(job.toString())
        kick()
    }

    fun hasPending() = pendingDir.listFiles { f -> f.extension == "json" }?.isNotEmpty() == true

    /** Obradi sve što čeka (pozvati i pri pokretanju aplikacije). */
    fun kick() {
        executor.execute { drain() }
    }

    private fun drain() {
        val jobs = pendingDir.listFiles { f -> f.extension == "json" }?.sortedBy { it.lastModified() } ?: return
        for (jobFile in jobs) {
            val config = configProvider() ?: return
            try {
                runJob(jobFile, config)
                onError(null)
            } catch (e: Exception) {
                Log.e(RelayClient.TAG, "upload ${jobFile.name} nije uspio", e)
                onError("Upload: ${e.message}")
                // Ponovi cijeli red za 30 s; dijelovi koji su prošli ostaju zapisani.
                executor.execute { Thread.sleep(30_000); drain() }
                return
            }
        }
    }

    private fun runJob(jobFile: File, config: RelayConfig) {
        val job = JSONObject(jobFile.readText())
        val video = File(job.getString("video"))
        val sidecar = File(job.getString("sidecar"))
        val total = video.length()
        if (!video.exists()) throw IllegalStateException("nema datoteke ${video.name}")

        if (!job.has("uploadId")) {
            val res = call(
                Request.Builder().url("${config.httpBase}/v1/upload/create")
                    .post(JSONObject().put("sessionId", job.getString("sessionId")).put("camera", job.getString("camera"))
                        .put("file", video.name).toString().toRequestBody(json)),
                config,
            )
            job.put("objectKey", res.getString("objectKey")).put("uploadId", res.getString("uploadId")).put("partSize", res.getLong("partSize"))
            job.put("parts", JSONArray())
            jobFile.writeText(job.toString())
        }
        val objectKey = job.getString("objectKey")
        val uploadId = job.getString("uploadId")
        val partSize = job.getLong("partSize")
        val parts = job.getJSONArray("parts")
        val partCount = ((total + partSize - 1) / partSize).toInt()

        for (n in (parts.length() + 1)..partCount) {
            val offset = (n - 1) * partSize
            val length = minOf(partSize, total - offset)
            val url = "${config.httpBase}/v1/upload/part?objectKey=${enc(objectKey)}&uploadId=${enc(uploadId)}&part=$n"
            val res = retry {
                call(Request.Builder().url(url).put(FileRange(video, offset, length) { done -> onProgress(offset + done, total) }), config)
            }
            parts.put(JSONObject().put("partNumber", res.getInt("partNumber")).put("etag", res.getString("etag")))
            job.put("parts", parts)
            jobFile.writeText(job.toString())
            onProgress(offset + length, total)
        }

        val done = retry {
            call(
                Request.Builder().url("${config.httpBase}/v1/upload/complete")
                    .post(JSONObject().put("objectKey", objectKey).put("uploadId", uploadId).put("parts", parts).toString().toRequestBody(json)),
                config,
            )
        }
        if (done.optLong("size") != total) throw IllegalStateException("R2 javlja ${done.optLong("size")} B, lokalno $total B")

        val sidecarKey = retry {
            call(
                Request.Builder().url(
                    "${config.httpBase}/v1/object?sessionId=${enc(job.getString("sessionId"))}&camera=${enc(job.getString("camera"))}&file=${enc(sidecar.name)}",
                ).put(sidecar.readBytes().toRequestBody(json)),
                config,
            ).getString("objectKey")
        }

        Log.i(RelayClient.TAG, "uploadano: $objectKey ($total B), $sidecarKey; lokalno ostaje ${video.absolutePath}")
        jobFile.delete()
        onDone(job.getString("sessionId"), job.getString("takeId"), listOf(objectKey, sidecarKey))
    }

    private fun <T> retry(block: () -> T): T {
        var delay = 2000L
        repeat(4) {
            try {
                return block()
            } catch (e: Exception) {
                Log.w(RelayClient.TAG, "pokušaj nije uspio: ${e.message}")
                Thread.sleep(delay)
                delay *= 2
            }
        }
        return block()
    }

    private fun call(builder: Request.Builder, config: RelayConfig): JSONObject {
        http.newCall(builder.header("Authorization", "Bearer ${config.key}").build()).execute().use { r ->
            val body = r.body.string()
            if (!r.isSuccessful) throw IllegalStateException("HTTP ${r.code}: ${body.take(200)}")
            return JSONObject(body)
        }
    }

    private fun enc(s: String) = android.net.Uri.encode(s)

    /** Tijelo zahtjeva = komad datoteke, čita se u blokovima, s napretkom. */
    private inner class FileRange(val file: File, val offset: Long, val length: Long, val progress: (Long) -> Unit) : RequestBody() {
        override fun contentType() = octet
        override fun contentLength() = length
        override fun writeTo(sink: BufferedSink) {
            RandomAccessFile(file, "r").use { raf ->
                raf.seek(offset)
                val buf = ByteArray(256 * 1024)
                var done = 0L
                var lastReport = 0L
                while (done < length) {
                    val n = raf.read(buf, 0, minOf(buf.size.toLong(), length - done).toInt())
                    if (n < 0) throw IllegalStateException("datoteka kraća od očekivanog")
                    sink.write(buf, 0, n)
                    done += n
                    if (done - lastReport > 2 * 1024 * 1024) {
                        progress(done)
                        lastReport = done
                    }
                }
            }
        }
    }
}
