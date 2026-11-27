package app.dikiz

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.PowerManager
import android.view.OrientationEventListener
import android.view.Surface
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Kamera + HTTP sunucusu bu ön plan servisinde yaşar; böylece telefon kilitlense ya da
 * başka uygulamaya geçilse de Mac'teki görüntü kesilmez. Ekran (MainActivity) yalnızca
 * önizleme ve birkaç buton gösterir.
 */
class DikizService : LifecycleService() {

    class Running(val camera: CameraController, val hub: FrameHub, val port: Int, val code: String, val server: HttpServer, val audio: AudioHub, val speaker: SpeakerSink)

    private var server: HttpServer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        goForeground()

        val hub = FrameHub()
        val camera = CameraController(this, this, hub)
        val code = accessCode(this)
        val audio = AudioHub(this)
        val speaker = SpeakerSink()
        val srv = HttpServer(this, hub, camera, code, audio, speaker)
        val port = srv.start()
        server = srv
        camera.start()

        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Dikiz:stream")
            .apply { acquire(4 * 60 * 60 * 1000L) }

        running.value = Running(camera, hub, port, code, srv, audio, speaker)
        // Bildirim canlı durumu gösterir: kimse bağlı değil / Mac'e bağlı, mikrofon ve Mac sesi
        lifecycleScope.launch {
            combine(hub.clientCount, audio.listeners, speaker.playing, camera.state) { v, mic, spk, st ->
                Live(v, mic, spk, if (st.height > 0) minOf(st.width, st.height) else 0)
            }.collect { live ->
                if (live != lastLive) {
                    lastLive = live
                    getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(live))
                }
            }
        }
        advertise(port)

        // Telefonun duruşunu izle (dik / yatay / ters) → görüntü hep düz gider.
        orientation = object : OrientationEventListener(this) {
            override fun onOrientationChanged(o: Int) {
                if (o == ORIENTATION_UNKNOWN) return
                val r = when (o) {
                    in 50..130 -> Surface.ROTATION_270
                    in 140..220 -> Surface.ROTATION_180
                    in 230..310 -> Surface.ROTATION_90
                    in 0..40, in 320..359 -> Surface.ROTATION_0
                    else -> return        // köşe bölgelerinde titremesin
                }
                camera.setDeviceRotation(r)
            }
        }.also { if (it.canDetectOrientation()) it.enable() }
    }

    private var orientation: OrientationEventListener? = null

    // ---- Bonjour / mDNS: Mac'teki Dikiz uygulaması telefonu adres yazmadan bulur ----
    private var nsd: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null

    // İlanda eşleşme kodu, ad ve model YOK: yalnızca rastgele kalıcı kimlik.
    // Mac kullanıcının girdiği kodu ağdaki Dikiz telefonlarına sorar; kabul edenle eşleşir.
    private fun advertise(port: Int) {
        if (port == 0) return
        val info = NsdServiceInfo().apply {
            serviceName = "Dikiz"
            serviceType = "_dikiz._tcp"
            this.port = port
            // Gizlilik: yalnızca rastgele kimlik. Telefonun adı ve modeli ancak kodla (/api/state) görülür.
            setAttribute("id", deviceId(this@DikizService))
            setAttribute("v", "2")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(si: NsdServiceInfo) {}
            override fun onRegistrationFailed(si: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(si: NsdServiceInfo) {}
            override fun onUnregistrationFailed(si: NsdServiceInfo, errorCode: Int) {}
        }
        runCatching {
            nsd = getSystemService(NsdManager::class.java)
            nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            nsdListener = listener
        }
    }

    /** Mikrofon izni varsa ön plan türüne mikrofonu da ekle (Android 14: arka planda ses için şart). */
    private fun goForeground() {
        var type = 0
        if (Build.VERSION.SDK_INT >= 30) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            val mic = ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            if (mic) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(), type)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        runCatching { goForeground() }   // izin sonradan verildiyse mikrofon türünü ekle
        return START_NOT_STICKY
    }

    /** Uygulama son kullanılanlardan kaydırılıp kapatılırsa yayını da bitir. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running.value = null
        orientation?.disable()
        nsdListener?.let { l -> runCatching { nsd?.unregisterService(l) } }
        nsdListener = null
        server?.stop()
        server = null
        wakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Yayın", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private data class Live(val viewers: Int, val mic: Int, val macSound: Boolean, val res: Int)
    private var lastLive: Live? = null

    private fun buildNotification(live: Live? = null): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, DikizService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val connected = live != null && (live.viewers > 0 || live.mic > 0 || live.macSound)
        val title = if (connected) "Dikiz: Mac'e bağlı" else "Dikiz açık"
        val parts = mutableListOf<String>()
        if (live != null && live.viewers > 0) parts += if (live.res > 0) "kamera ${live.res}p" else "kamera"
        if (live != null && live.mic > 0) parts += "mikrofon"
        if (live != null && live.macSound) parts += "Mac sesi çalıyor"
        val text = if (parts.isEmpty()) "Mac'te Dikiz'i aç, ekrandaki kodu gir" else parts.joinToString(", ").replaceFirstChar { it.uppercase() }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_dikiz)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "Kapat", stop)
            // Android 16 canlı güncelleme: durum çubuğunda (kamera çentiğinin yanında) "Canlı" çipi
            .setRequestPromotedOngoing(true)
            .setShortCriticalText(if (connected) "Canlı" else "Dikiz")
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        const val ACTION_STOP = "app.dikiz.STOP"
        private const val CHANNEL = "stream"
        private const val NOTIF_ID = 7
        val running = MutableStateFlow<Running?>(null)

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, DikizService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, DikizService::class.java).setAction(ACTION_STOP))
        }

        /** 6 haneli eşleşme kodu; telefon yeniden başlasa da aynı kalır, istenirse değiştirilir. */
        fun accessCode(context: Context): String {
            val prefs = context.getSharedPreferences("app", MODE_PRIVATE)
            return prefs.getString("pin", null) ?: newPin().also { prefs.edit().putString("pin", it).apply() }
        }

        /** Yeni kod üret, kaydet ve çalışan sunucuya uygula (bağlı Mac'ler yeni kodu ister). */
        fun changeCode(context: Context) {
            val c = newPin()
            context.getSharedPreferences("app", MODE_PRIVATE).edit().putString("pin", c).apply()
            running.value?.let { r ->
                r.server.changeCode(c)
                running.value = Running(r.camera, r.hub, r.port, c, r.server, r.audio, r.speaker)
            }
        }

        private fun newPin(): String {
            val rnd = java.security.SecureRandom()
            return (1..6).map { rnd.nextInt(10) }.joinToString("")
        }

        /** Telefonu aynı ağdaki diğer telefonlardan ayıran kalıcı kimlik (gizli değil). */
        fun deviceId(context: Context): String {
            val prefs = context.getSharedPreferences("app", MODE_PRIVATE)
            return prefs.getString("id", null) ?: java.util.UUID.randomUUID().toString().replace("-", "").take(12)
                .also { prefs.edit().putString("id", it).apply() }
        }

        /** Telefonun ayarlardaki adı (ör. "Ali'nin Xiaomi 15"); yoksa model. */
        fun deviceName(context: Context): String {
            val n = if (Build.VERSION.SDK_INT >= 25)
                android.provider.Settings.Global.getString(context.contentResolver, android.provider.Settings.Global.DEVICE_NAME)
            else null
            return n?.takeIf { it.isNotBlank() } ?: Build.MODEL
        }
    }
}
