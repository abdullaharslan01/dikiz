package app.dikiz

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

@OptIn(ExperimentalCamera2Interop::class)
class CameraController(
    private val context: Context,
    private val owner: LifecycleOwner,
    private val hub: FrameHub,
) {
    data class CamInfo(val id: String, val label: String, val facing: Int, val fov: Int)

    data class State(
        val cameras: List<CamInfo> = emptyList(),
        val cameraId: String? = null,
        val sizes: List<Size> = emptyList(),
        val targetSize: Size? = null,
        val width: Int = 0,
        val height: Int = 0,
        val rotation: Int = 0,
        val zoomMin: Float = 1f,
        val zoomMax: Float = 1f,
        val zoom: Float = 1f,
        val hasFlash: Boolean = false,
        val torch: Boolean = false,
        val evMin: Int = 0,
        val evMax: Int = 0,
        val ev: Int = 0,
        val evStep: Float = 0f,
        val quality: Int = 80,
        val maxFps: Int = 30,
        val fps: Float = 0f,
        val phonePreview: Boolean = true,
        val focusLocked: Boolean = false,
        val error: String? = null,
        // --- gelişmiş (Camera2) ---
        val lensStops: List<Float> = emptyList(),   // ör. 0.6, 1, 2.6 (geniş / ana / tele)
        val minFocusDiopter: Float = 0f,             // 0 = elle odak desteklenmiyor
        val manualFocus: Float? = null,              // diyoptri; null = otomatik
        val aeLock: Boolean = false,
        val awbLock: Boolean = false,
        val hq: Boolean = true,                      // kenar + gürültü azaltma yüksek kalite
        val supports60: Boolean = false,
    )

    private val prefs = context.getSharedPreferences("camera", Context.MODE_PRIVATE)
    val state = MutableStateFlow(
        State(
            cameraId = prefs.getString("cameraId", null),
            targetSize = prefs.getString("size", null)?.let { runCatching { Size.parseSize(it) }.getOrNull() },
            quality = prefs.getInt("quality", 80),
            maxFps = prefs.getInt("maxFps", 30),
            phonePreview = prefs.getBoolean("phonePreview", true),
            zoom = prefs.getFloat("zoom", 1f),
            hq = prefs.getBoolean("hq", true),
        )
    )

    private val main = ContextCompat.getMainExecutor(context)
    private val encodeExecutor = Executors.newSingleThreadExecutor()
    private val encoder = JpegEncoder()
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var analysis: ImageAnalysis? = null
    private var surfaceProvider: Preview.SurfaceProvider? = null

    // ---------- yaşam döngüsü ----------

    fun start() {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            provider = future.get()
            loadCameras()
            bind()
        }, main)
    }

    fun setSurfaceProvider(sp: Preview.SurfaceProvider?) {
        if (sp === surfaceProvider) return
        surfaceProvider = sp
        if (provider != null) bind()
    }

    private fun loadCameras() {
        val p = provider ?: return
        val list = p.availableCameraInfos.mapNotNull { info ->
            runCatching {
                val c2 = Camera2CameraInfo.from(info)
                val facing = c2.getCameraCharacteristic(CameraCharacteristics.LENS_FACING) ?: -1
                val focal = c2.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.minOrNull()
                val sensor = c2.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                val fov = if (focal != null && sensor != null && focal > 0f)
                    Math.toDegrees(2 * atan(max(sensor.width, sensor.height) / (2.0 * focal))).roundToInt()
                else 0
                val name = when (facing) {
                    CameraCharacteristics.LENS_FACING_BACK -> "Arka"
                    CameraCharacteristics.LENS_FACING_FRONT -> "Ön"
                    else -> "Harici"
                }
                CamInfo(c2.cameraId, "$name kamera · ${if (fov > 0) "$fov°" else "?"} (id ${c2.cameraId})", facing, fov)
            }.getOrNull()
        }.sortedWith(compareBy<CamInfo> { if (it.facing == CameraCharacteristics.LENS_FACING_BACK) 0 else 1 })
        state.update { it.copy(cameras = list) }
    }

    private fun sizesFor(cameraId: String): List<Size> {
        val p = provider ?: return emptyList()
        val info = p.availableCameraInfos.firstOrNull { Camera2CameraInfo.from(it).cameraId == cameraId } ?: return emptyList()
        val map = Camera2CameraInfo.from(info)
            .getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        return (map.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray())
            .filter { it.width >= 176 && it.height >= 144 }   // 144p'ye kadar: yavaş internet için
            .distinct()
            .sortedByDescending { it.width.toLong() * it.height }
    }

    @SuppressLint("RestrictedApi")
    private fun bind() {
        val p = provider ?: return
        val s = state.value
        val camId = s.cameraId?.takeIf { id -> s.cameras.any { it.id == id } }
            ?: s.cameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_BACK }?.id
            ?: s.cameras.firstOrNull()?.id
        if (camId == null) {
            state.update { it.copy(error = "Kamera bulunamadı") }
            return
        }
        val sizes = sizesFor(camId)
        val target = s.targetSize?.takeIf { it in sizes }
            ?: sizes.firstOrNull { it.width <= 1920 && it.height <= 1080 && abs(it.width.toFloat() / it.height - 16f / 9f) < 0.05f }
            ?: sizes.firstOrNull { it.width <= 1920 }
            ?: Size(1280, 720)

        camera?.cameraInfo?.let { info ->
            info.zoomState.removeObservers(owner)
            info.torchState.removeObservers(owner)
        }
        p.unbindAll()

        val selector = CameraSelector.Builder()
            .addCameraFilter { infos -> infos.filter { Camera2CameraInfo.from(it).cameraId == camId } }
            .build()
        val ratio = target.width.toFloat() / target.height
        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(
                if (abs(ratio - 4f / 3f) < 0.05f) AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
                else AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY
            )
            .setResolutionStrategy(
                ResolutionStrategy(target, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)
            )
            .setResolutionFilter { supported, _ ->
                // Tam eşleşme varsa en başa al.
                supported.sortedBy { if (it == target) 0 else 1 }
            }
            .build()

        val ia = ImageAnalysis.Builder()
            .setResolutionSelector(resolutionSelector)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setTargetRotation(targetRotation)
            .build()
        ia.setAnalyzer(encodeExecutor, ::analyze)
        analysis = ia

        val useCases = mutableListOf<UseCase>(ia)
        val sp = surfaceProvider
        if (s.phonePreview && sp != null) {
            useCases += Preview.Builder().build().also { it.setSurfaceProvider(sp) }
        }

        try {
            val cam = p.bindToLifecycle(owner, selector, *useCases.toTypedArray())
            camera = cam
            val info = cam.cameraInfo
            val exp = info.exposureState
            val c2 = Camera2CameraInfo.from(info)
            val zr = if (android.os.Build.VERSION.SDK_INT >= 30)
                c2.getCameraCharacteristic(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) else null
            val zMin = zr?.lower ?: info.zoomState.value?.minZoomRatio ?: 1f
            val zMax = zr?.upper ?: info.zoomState.value?.maxZoomRatio ?: 1f
            val minFocus = c2.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
            val fpsRanges = c2.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            state.update {
                it.copy(
                    cameraId = camId, sizes = sizes, targetSize = target,
                    hasFlash = info.hasFlashUnit(),
                    evMin = exp.exposureCompensationRange.lower,
                    evMax = exp.exposureCompensationRange.upper,
                    ev = exp.exposureCompensationIndex,
                    evStep = exp.exposureCompensationStep.toFloat(),
                    focusLocked = false, error = null,
                    lensStops = lensStops(camId, zMin, zMax),
                    minFocusDiopter = minFocus,
                    manualFocus = null, aeLock = false, awbLock = false,
                    supports60 = fpsRanges?.any { r -> r.upper >= 60 && r.lower >= 30 } == true,
                )
            }
            applyCamera2Options()
            info.zoomState.observe(owner) { z ->
                state.update { it.copy(zoomMin = z.minZoomRatio, zoomMax = z.maxZoomRatio, zoom = z.zoomRatio) }
            }
            info.torchState.observe(owner) { t -> state.update { it.copy(torch = t == 1) } }
            // İlk açılışta arka kamerada geniş açıyı (0.6× gibi) varsayılan yap: telefonu tam
            // doğru açıya koymak gerekmez, Mac'te yakınlaştırıp kaydırılır.
            val isBack = s.cameras.firstOrNull { it.id == camId }?.facing == CameraCharacteristics.LENS_FACING_BACK
            val minZoom = (if (android.os.Build.VERSION.SDK_INT >= 30)
                Camera2CameraInfo.from(info).getCameraCharacteristic(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.lower
            else null) ?: info.zoomState.value?.minZoomRatio ?: 1f
            val startZoom = if (prefs.contains("zoom")) prefs.getFloat("zoom", 1f)
                else if (isBack && minZoom < 1f) minZoom else 1f
            if (startZoom != 1f) cam.cameraControl.setZoomRatio(startZoom)
        } catch (e: Exception) {
            Log.e(TAG, "bind failed", e)
            state.update { it.copy(error = "Kamera açılamadı: ${e.message}") }
        }
    }

    // ---------- kare işleme ----------

    private var lastEncode = 0L
    private var fpsFrames = 0
    private var fpsWindow = 0L

    private fun analyze(image: androidx.camera.core.ImageProxy) {
        try {
            if (!hub.wantsFrames()) return
            val s = state.value
            val now = SystemClock.elapsedRealtime()
            val minInterval = 1000L / s.maxFps.coerceIn(1, 60)
            if (now - lastEncode < minInterval - 3) return
            lastEncode = now
            val rot = image.imageInfo.rotationDegrees
            val jpeg = encoder.encode(image, s.quality)
            hub.publish(jpeg, image.width, image.height, rot)

            fpsFrames++
            if (now - fpsWindow >= 1000) {
                val fps = fpsFrames * 1000f / (now - fpsWindow).coerceAtLeast(1)
                fpsFrames = 0
                fpsWindow = now
                state.update { it.copy(fps = fps, width = image.width, height = image.height, rotation = rot) }
            } else if (s.width != image.width || s.rotation != rot) {
                state.update { it.copy(width = image.width, height = image.height, rotation = rot) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "encode failed", e)
        } finally {
            image.close()
        }
    }

    // ---------- ayarlar (her iş parçacığından çağrılabilir) ----------

    fun set(key: String, value: String) {
        main.execute { applySetting(key, value) }
    }

    private fun applySetting(key: String, value: String) {
        val control = camera?.cameraControl
        when (key) {
            "camera" -> {
                prefs.edit().putString("cameraId", value).remove("size").remove("zoom").apply()
                state.update { it.copy(cameraId = value, targetSize = null) }
                bind()
            }
            "size" -> runCatching { Size.parseSize(value) }.getOrNull()?.let { sz ->
                prefs.edit().putString("size", sz.toString()).apply()
                state.update { it.copy(targetSize = sz) }
                bind()
            }
            "zoom" -> value.toFloatOrNull()?.let { z ->
                val s = state.value
                val zz = z.coerceIn(s.zoomMin, s.zoomMax)
                prefs.edit().putFloat("zoom", zz).apply()
                control?.setZoomRatio(zz)
            }
            "torch" -> control?.enableTorch(value == "1" || value == "true")
            "ev" -> value.toIntOrNull()?.let { ev ->
                val s = state.value
                val e = ev.coerceIn(s.evMin, s.evMax)
                control?.setExposureCompensationIndex(e)
                state.update { it.copy(ev = e) }
            }
            // Hazır kalite: 1080 / 720 / 480 / 360 / 240 / 144 → boyut + JPEG kalitesi + kare hızı birlikte
            "preset" -> value.toIntOrNull()?.let { h ->
                val (q, fps) = presetParams(h)
                prefs.edit().putInt("preset", h).apply()
                applySetting("quality", q.toString())
                applySetting("fps", fps.toString())
                pickSize(state.value.sizes, h)?.let { applySetting("size", it.toString()) }
            }
            "quality" -> value.toIntOrNull()?.let { q ->
                val qq = q.coerceIn(30, 100)
                prefs.edit().putInt("quality", qq).apply()
                state.update { it.copy(quality = qq) }
            }
            "fps" -> value.toIntOrNull()?.let { f ->
                val ff = f.coerceIn(1, 60)
                prefs.edit().putInt("maxFps", ff).apply()
                state.update { it.copy(maxFps = ff) }
                applyCamera2Options()
            }
            "focusDist" -> {
                val d = value.toFloatOrNull()
                state.update { it.copy(manualFocus = d?.coerceIn(0f, it.minFocusDiopter), focusLocked = false) }
                if (d == null) control?.cancelFocusAndMetering()
                applyCamera2Options()
            }
            "aelock" -> { state.update { it.copy(aeLock = value == "1") }; applyCamera2Options() }
            "awblock" -> { state.update { it.copy(awbLock = value == "1") }; applyCamera2Options() }
            "hq" -> {
                prefs.edit().putBoolean("hq", value == "1").apply()
                state.update { it.copy(hq = value == "1") }
                applyCamera2Options()
            }
            "preview" -> {
                val on = value == "1" || value == "true"
                prefs.edit().putBoolean("phonePreview", on).apply()
                state.update { it.copy(phonePreview = on) }
                bind()
            }
            "focus" -> {
                val parts = value.split(",").mapNotNull { it.toFloatOrNull() }
                val ia = analysis
                if (parts.size == 2 && ia != null && control != null) {
                    if (state.value.manualFocus != null) {
                        state.update { it.copy(manualFocus = null) }
                        applyCamera2Options()
                    }
                    val point = SurfaceOrientedMeteringPointFactory(1f, 1f, ia)
                        .createPoint(parts[0].coerceIn(0f, 1f), parts[1].coerceIn(0f, 1f))
                    control.startFocusAndMetering(
                        FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
                            .disableAutoCancel()
                            .build()
                    )
                    state.update { it.copy(focusLocked = true) }
                }
            }
            "autofocus" -> {
                control?.cancelFocusAndMetering()
                state.update { it.copy(focusLocked = false, manualFocus = null) }
                applyCamera2Options()
            }
        }
    }

    /**
     * Çoklu kameralı telefonlarda (Xiaomi 15: geniş + ana + tele) her fiziksel lensin
     * zoom karşılığını odak uzaklığından hesaplar.
     */
    private fun lensStops(camId: String, zMin: Float, zMax: Float): List<Float> {
        val stops = mutableListOf(1f)
        if (zMin < 0.95f) stops += zMin
        runCatching {
            val cm = context.getSystemService(CameraManager::class.java)
            val logical = cm.getCameraCharacteristics(camId)
            fun eq(ch: CameraCharacteristics): Float? {
                val f = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return null
                val ss = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
                return f * 43.27f / hypot(ss.width, ss.height)
            }
            val main = eq(logical)
            if (main != null && android.os.Build.VERSION.SDK_INT >= 28) {
                logical.physicalCameraIds.forEach { id ->
                    eq(cm.getCameraCharacteristics(id))?.let { e -> stops += ((e / main) * 10).roundToInt() / 10f }
                }
            }
        }
        if (stops.none { it > 1.5f } && zMax >= 2f) stops += 2f
        return stops
            .filter { it >= zMin - 0.05f && it <= zMax + 0.01f }
            .map { if (abs(it - 1f) < 0.15f) 1f else ((it * 10).roundToInt() / 10f) }
            .distinct().sorted()
    }

    /** Elle odak, AE/AWB kilidi, yüksek kalite ve 60 fps gibi Camera2 seçeneklerini uygular. */
    private fun applyCamera2Options() {
        val cam = camera ?: return
        val s = state.value
        val b = CaptureRequestOptions.Builder()
        s.manualFocus?.let { d ->
            b.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
            b.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, d)
        }
        if (s.aeLock) b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, true)
        if (s.awbLock) b.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, true)
        if (s.hq) {
            b.setCaptureRequestOption(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_HIGH_QUALITY)
            b.setCaptureRequestOption(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY)
        }
        if (s.maxFps >= 60 && s.supports60) {
            b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(60, 60))
        }
        runCatching { Camera2CameraControl.from(cam.cameraControl).setCaptureRequestOptions(b.build()) }
            .onFailure { Log.w(TAG, "camera2 options", it) }
    }

    /**
     * Telefonun fiziksel duruşu (Surface.ROTATION_*). Kareler buna göre "dik" döndürme
     * bilgisiyle gönderilir; telefon yatay da dursa toplantıdaki görüntü düz olur.
     */
    @Volatile private var targetRotation: Int = android.view.Surface.ROTATION_0

    fun setDeviceRotation(rotation: Int) {
        if (rotation == targetRotation) return
        targetRotation = rotation
        main.execute { analysis?.targetRotation = rotation }
    }

    /** Geniş açı (en düşük zoom) ile 1× arasında geçiş. */
    fun toggleWide() {
        val s = state.value
        set("zoom", if (s.zoom < 0.99f) "1" else s.zoomMin.toString())
    }

    /** Arka ↔ ön kamera. */
    private fun pickSize(sizes: List<Size>, h: Int): Size? {
        // Kısa kenarı hedefe en yakın boyut (önce eşit/büyük olanlar)
        val up = sizes.filter { minOf(it.width, it.height) >= h }.minByOrNull { minOf(it.width, it.height) }
        val down = sizes.filter { minOf(it.width, it.height) < h }.maxByOrNull { minOf(it.width, it.height) }
        if (up == null) return down
        if (down == null) return up
        return if (minOf(up.width, up.height) - h <= (h - minOf(down.width, down.height)) * 1.5) up else down
    }

    /** Şu anki kalite (kullanıcı seçmediyse çözünürlükten tahmin). */
    fun currentPreset(): Int {
        val saved = prefs.getInt("preset", 0)
        if (saved > 0) return saved
        val s = state.value
        val m = minOf(s.width, s.height).takeIf { it > 0 } ?: 720
        return PRESETS.minByOrNull { kotlin.math.abs(it - m) } ?: 720
    }

    fun switchFacing() {
        val s = state.value
        val current = s.cameras.firstOrNull { it.id == s.cameraId }?.facing
        val target = s.cameras.firstOrNull { it.facing != current } ?: return
        set("camera", target.id)
    }

    val isWide: Boolean get() = state.value.zoom < 0.99f

    fun stateJson(): String {
        val s = state.value
        return JSONObject().apply {
            put("cameras", JSONArray().apply {
                s.cameras.forEach { c ->
                    val facing = when (c.facing) {
                        CameraCharacteristics.LENS_FACING_FRONT -> "front"
                        CameraCharacteristics.LENS_FACING_BACK -> "back"
                        else -> "external"
                    }
                    put(JSONObject().put("id", c.id).put("label", c.label).put("fov", c.fov).put("facing", facing))
                }
            })
            put("cameraId", s.cameraId)
            put("sizes", JSONArray().apply { s.sizes.forEach { put(it.toString()) } })
            put("targetSize", s.targetSize?.toString())
            put("width", s.width)
            put("height", s.height)
            put("rotation", s.rotation)
            put("zoomMin", s.zoomMin.toDouble())
            put("zoomMax", s.zoomMax.toDouble())
            put("zoom", s.zoom.toDouble())
            put("hasFlash", s.hasFlash)
            put("torch", s.torch)
            put("evMin", s.evMin)
            put("evMax", s.evMax)
            put("ev", s.ev)
            put("evStep", s.evStep.toDouble())
            put("quality", s.quality)
            put("preset", currentPreset())
            put("deviceName", DikizService.deviceName(context))
            put("maxFps", s.maxFps)
            put("fps", s.fps.toDouble())
            put("phonePreview", s.phonePreview)
            put("focusLocked", s.focusLocked)
            put("lensStops", JSONArray().apply { s.lensStops.forEach { put(it.toDouble()) } })
            put("minFocusDiopter", s.minFocusDiopter.toDouble())
            put("manualFocus", s.manualFocus?.toDouble() ?: JSONObject.NULL)
            put("aeLock", s.aeLock)
            put("awbLock", s.awbLock)
            put("hq", s.hq)
            put("supports60", s.supports60)
            put("clients", hub.clientCount.value)
            put("error", s.error)
        }.toString()
    }

    companion object { private const val TAG = "Dikiz" }
}

val PRESETS = listOf(1080, 720, 480, 360, 240, 144)

/** Kalite adımına göre JPEG kalitesi ve kare hızı (yavaş internette daha az veri). */
fun presetParams(h: Int): Pair<Int, Int> = when {
    h >= 1080 -> 85 to 30
    h >= 720 -> 80 to 30
    h >= 480 -> 70 to 25
    h >= 360 -> 60 to 20
    h >= 240 -> 50 to 15
    else -> 40 to 10
}
