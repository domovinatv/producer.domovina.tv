package tv.domovina.multicam

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

class MainActivity : ComponentActivity() {
    private lateinit var controller: CameraController
    private var previewView: PreviewView? = null

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        previewView?.let { controller.bind(this, it) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        controller = CameraController(applicationContext)
        controller.config.apply(intent?.data)
        controller.connect()

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Screen(controller, onPreview = { pv ->
                    previewView = pv
                    if (hasPermissions()) controller.bind(this, pv)
                    else permissions.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
                })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (controller.config.apply(intent.data)) {
            controller.connect()
        }
    }

    override fun onDestroy() {
        controller.shutdown()
        super.onDestroy()
    }

    private fun hasPermissions() = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO).all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }
}

@Composable
private fun Screen(c: CameraController, onPreview: (PreviewView) -> Unit) {
    var showSettings by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx -> PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FIT_CENTER; onPreview(this) } },
        )

        // Gore lijevo: veza, soba, ime kamere.
        Row(
            Modifier.align(Alignment.TopStart).padding(16.dp).clip(RoundedCornerShape(8.dp))
                .background(Color(0x99000000)).clickable { showSettings = true }.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(12.dp).clip(CircleShape).background(if (c.connected) Color(0xFF43A047) else Color(0xFFE53935)))
            Spacer(Modifier.width(8.dp))
            val where = c.room?.let { "Soba $it" } ?: "Nije spojeno"
            Text("$where · ${c.cameraName}", color = Color.White, fontSize = 15.sp)
        }

        // Gore u sredini: REC i vrijeme.
        if (c.state == CamState.RECORDING) {
            val s = c.recordingSeconds.toLong()
            Row(
                Modifier.align(Alignment.TopCenter).padding(16.dp).clip(RoundedCornerShape(8.dp))
                    .background(Color(0xCCB71C1C)).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(14.dp).clip(CircleShape).background(Color.White))
                Spacer(Modifier.width(10.dp))
                Text(
                    "REC  %d:%02d:%02d".format(s / 3600, (s / 60) % 60, s % 60),
                    color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace,
                )
            }
        }

        // Dolje lijevo: upload, upozorenja, greške.
        Column(Modifier.align(Alignment.BottomStart).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (c.room == null) Label("Skeniraj QR kod iz studija (domovinacam:// link) da se kamera spoji.")
            c.scheduledInfo?.let { Label(it) }
            c.clockInfo?.let { if (c.connected) Label(it, Color(0xFFB0BEC5)) }
            c.uploadProgress?.let { (d, t) -> Label("Upload %d%% (%.0f / %.0f MB)".format(if (t > 0) 100 * d / t else 0, d / 1e6, t / 1e6)) }
            c.fpsInfo?.let { Label("⚠ $it") }
            c.lastError?.let { Label("⚠ $it", Color(0xFFFF8A80)) }
        }

        // Desno: ručno snimanje.
        Box(
            Modifier.align(Alignment.CenterEnd).padding(24.dp).size(72.dp).clip(CircleShape)
                .border(4.dp, Color.White, CircleShape).clickable { c.toggleManual() },
            contentAlignment = Alignment.Center,
        ) {
            val recording = c.state == CamState.RECORDING
            Box(
                Modifier.size(if (recording) 28.dp else 54.dp).clip(if (recording) RoundedCornerShape(4.dp) else CircleShape)
                    .background(Color(0xFFE53935)),
            )
        }
    }

    if (showSettings) {
        var name by remember { mutableStateOf(c.cameraName) }
        AlertDialog(
            onDismissRequest = { showSettings = false },
            title = { Text("Postavke kamere") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(name, { name = it }, label = { Text("Ime kamere") }, singleLine = true)
                    Text("Soba: ${c.config.relay?.room ?: "—"}")
                    Text("Relay: ${c.config.relay?.relay ?: "—"}", fontSize = 12.sp)
                    Text("Snimke: ${c.recordDir.path}", fontSize = 12.sp)
                }
            },
            confirmButton = { TextButton({ c.rename(name); showSettings = false }) { Text("Spremi") } },
            dismissButton = { TextButton({ showSettings = false }) { Text("Odustani") } },
        )
    }
}

@Composable
private fun Label(text: String, color: Color = Color.White) {
    Text(
        text, color = color, fontSize = 14.sp,
        modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(Color(0x99000000)).padding(horizontal = 10.dp, vertical = 6.dp),
    )
}
