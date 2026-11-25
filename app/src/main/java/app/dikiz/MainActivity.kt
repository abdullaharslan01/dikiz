package app.dikiz

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Cameraswitch
import androidx.compose.material.icons.rounded.FlashlightOn
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.PanoramaWideAngle
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay

private val Accent = Color(0xFFF5B841)
private val Glass = Color(0xB3101418)
private val Muted = Color(0xFFAAB4C0)
private val Live = Color(0xFF7BD88F)

class MainActivity : ComponentActivity() {
    private val hasPermission = mutableStateOf(false)
    private var previewView: PreviewView? = null
    private var visible = false

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            hasPermission.value = cameraGranted()
            if (hasPermission.value) DikizService.start(this)
        }

    private fun cameraGranted() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestPermissions() {
        val perms = mutableListOf(Manifest.permission.CAMERA)
        if (android.os.Build.VERSION.SDK_INT >= 33) perms += Manifest.permission.POST_NOTIFICATIONS
        permissionLauncher.launch(perms.toTypedArray())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        hasPermission.value = cameraGranted()
        if (hasPermission.value) DikizService.start(this) else requestPermissions()

        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Accent)) {
                val running by DikizService.running.collectAsState()
                val r = running
                if (!hasPermission.value || r == null) {
                    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                        if (!hasPermission.value) {
                            Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text("Dikiz'in kameraya erişmesi gerekiyor.", color = Color.White, textAlign = TextAlign.Center)
                                Spacer(Modifier.size(16.dp))
                                Button(onClick = ::requestPermissions) { Text("Kameraya izin ver", color = Color.Black) }
                            }
                        } else {
                            Text("Başlatılıyor…", color = Muted)
                        }
                    }
                } else {
                    DikizScreen(
                        camera = r.camera,
                        hub = r.hub,
                        port = r.port,
                        code = r.code,
                        onPreviewView = { pv ->
                            previewView = pv
                            r.camera.setSurfaceProvider(if (visible) pv?.surfaceProvider else null)
                        },
                        onDim = { dim ->
                            window.attributes = window.attributes.apply {
                                screenBrightness = if (dim) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            }
                        },
                        onStop = { DikizService.stop(this@MainActivity); finish() },
                    )
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        visible = true
        if (cameraGranted()) {
            hasPermission.value = true
            DikizService.start(this)
        }
        DikizService.running.value?.camera?.setSurfaceProvider(previewView?.surfaceProvider)
    }

    override fun onStop() {
        // Ekran kapanınca önizlemeyi bırak; yayın serviste sürer.
        visible = false
        DikizService.running.value?.camera?.setSurfaceProvider(null)
        super.onStop()
    }
}

@Composable
private fun DikizScreen(
    camera: CameraController,
    hub: FrameHub,
    port: Int,
    code: String,
    onPreviewView: (PreviewView?) -> Unit,
    onDim: (Boolean) -> Unit,
    onStop: () -> Unit,
) {
    val hasPermission = true
    val state by camera.state.collectAsState()
    val clients by hub.clientCount.collectAsState()
    var addresses by remember { mutableStateOf(HttpServer.localAddresses()) }
    var dimmed by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        while (true) { addresses = HttpServer.localAddresses(); delay(3000) }
    }
    DisposableEffect(dimmed) { onDim(dimmed); onDispose { } }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (hasPermission && state.phonePreview) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    PreviewView(ctx).apply {
                        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                        scaleType = PreviewView.ScaleType.FILL_CENTER
                        onPreviewView(this)
                    }
                },
                onRelease = { onPreviewView(null) },
            )
        }

        // ---- Üst: tek satırlık bağlantı rozeti (tek başına, ortada) ----
        Box(Modifier.align(Alignment.TopCenter).safeDrawingPadding().padding(top = 12.dp, start = 16.dp, end = 16.dp)) {
            val mode = when {
                clients > 0 -> 2
                port == 0 || addresses.isEmpty() -> 0
                else -> 1
            }
            AnimatedContent(targetState = mode, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "chip") { m ->
                when (m) {
                    0 -> Chip {
                        Icon(Icons.Rounded.WifiOff, null, tint = Color(0xFFFF8A80), modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Wi‑Fi'yi aç (Mac ile aynı ağ)", color = Color.White, fontSize = 14.sp)
                    }
                    1 -> Chip {
                        Icon(Icons.Rounded.Laptop, null, tint = Accent, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text("Mac'te Dikiz'i aç", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                "${addresses.first()}:$port/$code",
                                color = Muted, fontSize = 12.sp, maxLines = 1,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    }
                    else -> Chip {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(Live))
                        Spacer(Modifier.width(8.dp))
                        Text("Mac'e bağlı", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        if (state.width > 0) {
                            Text(
                                "  ·  ${state.height}p · ${"%.0f".format(state.fps)} fps",
                                color = Muted, fontSize = 13.sp, maxLines = 1,
                            )
                        }
                    }
                }
            }
        }

        // ---- Alt: üç sade buton ----
        Row(
            Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(bottom = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (state.zoomMin < 0.99f) {
                RoundAction(Icons.Rounded.PanoramaWideAngle, "Geniş", active = state.zoom < 0.99f) { camera.toggleWide() }
            }
            if (state.cameras.size > 1) {
                RoundAction(Icons.Rounded.Cameraswitch, "Çevir") { camera.switchFacing() }
            }
            if (state.hasFlash) {
                RoundAction(Icons.Rounded.FlashlightOn, "Fener", active = state.torch) {
                    camera.set("torch", if (state.torch) "0" else "1")
                }
            }
            RoundAction(Icons.Rounded.Bedtime, "Karart") { dimmed = true }
            RoundAction(Icons.Rounded.PowerSettingsNew, "Kapat", onClick = onStop)
        }

        state.error?.let {
            Text(
                it, color = Color(0xFFFF8A80), fontSize = 13.sp,
                modifier = Modifier.align(Alignment.Center).padding(24.dp),
            )
        }

        if (dimmed) {
            Box(
                Modifier.fillMaxSize().background(Color.Black)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { dimmed = false },
                contentAlignment = Alignment.Center,
            ) {
                Text("Yayın sürüyor · dokun", color = Color(0xFF2A2A2A), fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun Chip(content: @Composable () -> Unit) {
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(Glass).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

@Composable
private fun RoundAction(icon: ImageVector, label: String, active: Boolean = false, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(58.dp).clip(CircleShape)
                .background(if (active) Accent else Glass)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = label, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(26.dp))
        }
        Spacer(Modifier.size(6.dp))
        Text(label, color = Color.White, fontSize = 12.sp)
    }
}
