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
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Kamera + HTTP sunucusu bu ön plan servisinde yaşar; böylece telefon kilitlense ya da
 * başka uygulamaya geçilse de Mac'teki görüntü kesilmez. Ekran (MainActivity) yalnızca
 * önizleme ve birkaç buton gösterir.
 */
class DikizService : LifecycleService() {

    class Running(val camera: CameraController, val hub: FrameHub, val port: Int, val code: String)

    private var server: HttpServer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(), type)

        val hub = FrameHub()
        val camera = CameraController(this, this, hub)
        val code = accessCode(this)
        val srv = HttpServer(this, hub, camera, code)
        val port = srv.start()
        server = srv
        camera.start()

        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Dikiz:stream")
            .apply { acquire(4 * 60 * 60 * 1000L) }

        running.value = Running(camera, hub, port, code)
        advertise(port, code)

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

    private fun advertise(port: Int, code: String) {
        if (port == 0) return
        val info = NsdServiceInfo().apply {
            serviceName = "Dikiz"
            serviceType = "_dikiz._tcp"
            this.port = port
            setAttribute("code", code)
            setAttribute("model", Build.MODEL)
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
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

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, DikizService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_dikiz)
            .setContentTitle("Dikiz yayında")
            .setContentText("Kamera Mac'e aktarılıyor")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Durdur", stop)
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

        fun accessCode(context: Context): String {
            val prefs = context.getSharedPreferences("app", MODE_PRIVATE)
            return prefs.getString("code", null) ?: run {
                val chars = "abcdefghjkmnpqrstuvwxyz23456789"
                val c = (1..4).map { chars.random() }.joinToString("")
                prefs.edit().putString("code", c).apply()
                c
            }
        }
    }
}
