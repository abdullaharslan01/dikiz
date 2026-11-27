package app.dikiz

import android.content.Context
import android.net.Uri
import android.util.Log
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.Executors

/**
 * Aynı Wi-Fi ağındaki bilgisayarın tarayıcısına hizmet veren küçük HTTP sunucusu.
 *
 *  /{kod}/            -> izleme sayfası (index.html)
 *  /{kod}/stream      -> MJPEG canlı görüntü
 *  /{kod}/snapshot.jpg-> tek kare
 *  /{kod}/api/state   -> JSON durum
 *  /{kod}/api/set?k=v -> ayar değiştir
 *  /{kod}/audio       -> telefon mikrofonu: ham PCM s16le, mono, 48 kHz (yalnızca dinlenirken açık)
 *  POST /{kod}/speaker -> Mac'in sesi: ham PCM s16le, stereo, 48 kHz; telefon hoparlöründen çalar
 *
 * Kod (eşleşme kodu) yalnızca telefon ekranında görünür; Bonjour ilanında yer almaz.
 * Böylece aynı ağdaki başkası kamerayı açamaz. Yanlış kod denemeleri adres başına sınırlanır.
 */
class HttpServer(
    private val context: Context,
    private val hub: FrameHub,
    private val camera: CameraController,
    initialCode: String,
    private val audio: AudioHub,
    private val speaker: SpeakerSink,
) {
    @Volatile var code: String = initialCode
        private set

    /** Kodu değiştir ve açık bağlantıları kes: eski kodla bağlı olanlar yeni kodu girmek zorunda. */
    fun changeCode(newCode: String) {
        code = newCode
        synchronized(sockets) { sockets.forEach { runCatching { it.close() } }; sockets.clear() }
    }

    // ---- Kod deneme sınırı: adres başına 60 sn'de 20 yanlış → 60 sn kilit ----
    private class Tries(var count: Int, var since: Long, var lockedUntil: Long)
    private val tries = mutableMapOf<String, Tries>()

    private fun isLocked(ip: String): Boolean = synchronized(tries) {
        (tries[ip]?.lockedUntil ?: 0L) > System.currentTimeMillis()
    }

    private fun recordFailure(ip: String) = synchronized(tries) {
        val now = System.currentTimeMillis()
        val t = tries.getOrPut(ip) { Tries(0, now, 0L) }
        if (now - t.since > 60_000) { t.count = 0; t.since = now }
        t.count++
        if (t.count >= 20) { t.lockedUntil = now + 60_000; t.count = 0; t.since = now }
    }

    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()
    private val sockets = Collections.synchronizedSet(mutableSetOf<Socket>())
    @Volatile private var running = false

    var port: Int = 0
        private set

    fun start(): Int {
        if (running) return port
        for (p in 8080..8099) {
            try {
                server = ServerSocket(p).apply { reuseAddress = true }
                port = p
                break
            } catch (_: IOException) { }
        }
        val s = server ?: return 0
        running = true
        Thread({
            while (running) {
                try {
                    val client = s.accept()
                    sockets += client
                    pool.execute { handle(client) }
                } catch (_: IOException) {
                    if (!running) break
                }
            }
        }, "http-accept").start()
        return port
    }

    fun stop() {
        running = false
        runCatching { server?.close() }
        server = null
        synchronized(sockets) { sockets.forEach { runCatching { it.close() } }; sockets.clear() }
    }

    private fun handle(socket: Socket) {
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 15000
            val input = BufferedInputStream(socket.getInputStream())
            val requestLine = readLine(input) ?: return
            while (true) {
                val h = readLine(input) ?: break
                if (h.isEmpty()) break
            }
            socket.soTimeout = 0
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val uri = Uri.parse("http://x" + parts[1])
            val segs = uri.pathSegments
            val out = socket.getOutputStream()

            val ip = socket.inetAddress?.hostAddress ?: "?"
            if (segs.firstOrNull() == "favicon.ico") return send(out, 404, "text/plain", "".toByteArray())
            if (isLocked(ip)) {
                return send(out, 429, "text/html; charset=utf-8",
                    ("<meta name=viewport content='width=device-width'><body style='font:18px system-ui;padding:24px'>" +
                        "<h2>Çok fazla yanlış deneme</h2><p>Bir dakika sonra tekrar dene.</p>").toByteArray())
            }
            if (segs.isEmpty() || segs[0] != code) {
                if (segs.isNotEmpty()) recordFailure(ip)
                return send(out, 404, "text/html; charset=utf-8",
                    ("<meta name=viewport content='width=device-width'><body style='font:18px system-ui;padding:24px'>" +
                        "<h2>Eşleşme kodu eksik ya da değişmiş</h2><p>Telefondaki Dikiz ekranında yazan adresin tamamını aç " +
                        "(sonundaki kod dahil).</p>").toByteArray())
            }
            when (segs.getOrNull(1)) {
                null, "", "index.html" -> {
                    val html = context.assets.open("index.html").use { it.readBytes() }
                        .toString(Charsets.UTF_8).replace("__CODE__", code)
                    send(out, 200, "text/html; charset=utf-8", html.toByteArray())
                }
                "stream" -> stream(out)
                "audio" -> audioStream(out)
                "speaker" -> {
                    if (parts[0] != "POST") return send(out, 404, "text/plain", "yok".toByteArray())
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n".toByteArray())
                    out.flush()
                    speaker.play(input)
                }
                "snapshot.jpg" -> {
                    hub.requestFramesFor(3000)
                    val since = hub.latest?.seq ?: 0L
                    val frame = hub.awaitAfter(since, 2500) ?: hub.latest
                    if (frame == null) send(out, 503, "text/plain", "Kare yok".toByteArray())
                    else send(out, 200, "image/jpeg", frame.jpeg)
                }
                "api" -> when (segs.getOrNull(2)) {
                    "state" -> send(out, 200, "application/json", camera.stateJson().toByteArray())
                    "set" -> {
                        uri.queryParameterNames.forEach { k -> uri.getQueryParameter(k)?.let { camera.set(k, it) } }
                        send(out, 200, "application/json", "{\"ok\":true}".toByteArray())
                    }
                    else -> send(out, 404, "text/plain", "yok".toByteArray())
                }
                else -> send(out, 404, "text/plain", "yok".toByteArray())
            }
        } catch (e: IOException) {
            // istemci ayrıldı
        } catch (e: Exception) {
            Log.w("Dikiz", "http", e)
        } finally {
            sockets -= socket
            runCatching { socket.close() }
        }
    }

    private fun stream(out: OutputStream) {
        out.write(
            ("HTTP/1.1 200 OK\r\n" +
                "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
                "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                "Pragma: no-cache\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n").toByteArray()
        )
        out.flush()
        hub.clientJoined()
        try {
            var seq = 0L
            while (running) {
                val f = hub.awaitAfter(seq, 2000) ?: continue
                seq = f.seq
                out.write(
                    ("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${f.jpeg.size}\r\n" +
                        "X-Rotation: ${f.rotation}\r\n\r\n").toByteArray()
                )
                out.write(f.jpeg)
                out.write("\r\n".toByteArray())
                out.flush()
            }
        } finally {
            hub.clientLeft()
        }
    }

    private fun audioStream(out: OutputStream) {
        val client = audio.join()
            ?: return send(out, 403, "text/plain; charset=utf-8", "Mikrofon izni yok".toByteArray())
        try {
            out.write(
                ("HTTP/1.1 200 OK\r\nContent-Type: ${AudioHub.CONTENT_TYPE}\r\n" +
                    "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n").toByteArray()
            )
            out.flush()
            while (running) {
                val chunk = client.queue.poll(2, java.util.concurrent.TimeUnit.SECONDS) ?: continue
                out.write(chunk)
                out.flush()
            }
        } finally {
            audio.leave(client)
        }
    }

    private fun send(out: OutputStream, status: Int, type: String, body: ByteArray) {
        val reason = when (status) { 200 -> "OK"; 404 -> "Not Found"; 403 -> "Forbidden"; 429 -> "Too Many Requests"; 503 -> "Service Unavailable"; else -> "OK" }
        out.write(
            ("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray()
        )
        out.write(body)
        out.flush()
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c == -1) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            if (sb.length > 8192) return null
            sb.append(c.toChar())
        }
    }

    companion object {
        /** Telefonun yerel ağdaki IPv4 adresleri (Wi-Fi, hotspot vb.). */
        fun localAddresses(): List<String> = runCatching {
            val ifaces = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
            // Wi-Fi / hotspot / ethernet arayüzlerini tercih et; mobil veri (rmnet/ccmni) adresleri bilgisayardan erişilemez.
            val lan = ifaces.filter { n -> listOf("wlan", "swlan", "ap", "eth", "rndis", "usb").any { n.name.startsWith(it) } }
            lan
                .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
                .flatMap { nif -> nif.inetAddresses.toList().filterIsInstance<Inet4Address>().map { it.hostAddress ?: "" } }
                .filter { it.isNotEmpty() && (it.startsWith("192.168.") || it.startsWith("10.") || it.startsWith("172.")) }
                .distinct()
        }.getOrDefault(emptyList())
    }
}
