package app.dikiz

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Telefon mikrofonu → /<kod>/audio dinleyicileri.
 * Biçim: ham PCM, 16 bit işaretli little-endian, mono, 48 kHz; ~20 ms'lik parçalar.
 * Mikrofon yalnızca en az bir dinleyici bağlıyken açıktır.
 */
class AudioHub(private val context: Context) {
    class Client { val queue = ArrayBlockingQueue<ByteArray>(25) }   // ~0,5 sn; dolarsa eskiler atılır

    private val clients = CopyOnWriteArraySet<Client>()
    val listeners = MutableStateFlow(0)
    @Volatile private var thread: Thread? = null

    fun hasPermission() = ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
        PackageManager.PERMISSION_GRANTED

    fun join(): Client? {
        if (!hasPermission()) return null
        val c = Client()
        clients += c
        listeners.value = clients.size
        synchronized(this) { if (thread == null) startRecording() }
        return c
    }

    fun leave(c: Client) {
        clients -= c
        listeners.value = clients.size
    }

    @SuppressLint("MissingPermission")
    private fun startRecording() {
        val t = Thread({
            val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val rec = try {
                AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, maxOf(min, CHUNK * 4))
            } catch (e: Exception) { Log.w("Dikiz", "mikrofon", e); null }
            if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
                rec?.release()
                synchronized(this) { thread = null }
                return@Thread
            }
            val ns = if (NoiseSuppressor.isAvailable()) runCatching { NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true } }.getOrNull() else null
            rec.startRecording()
            try {
                while (clients.isNotEmpty()) {
                    val buf = ByteArray(CHUNK)
                    var off = 0
                    while (off < CHUNK) {
                        val n = rec.read(buf, off, CHUNK - off)
                        if (n <= 0) break
                        off += n
                    }
                    if (off <= 0) continue
                    val chunk = if (off == CHUNK) buf else buf.copyOf(off)
                    for (c in clients) {
                        if (!c.queue.offer(chunk)) { c.queue.poll(); c.queue.offer(chunk) }
                    }
                }
            } finally {
                runCatching { rec.stop() }
                ns?.release()
                rec.release()
                synchronized(this) {
                    thread = null
                    if (clients.isNotEmpty()) startRecording()   // tam kapanırken yeni dinleyici geldiyse
                }
            }
        }, "dikiz-audio")
        thread = t
        t.start()
    }

    companion object {
        const val RATE = 48000
        const val CHUNK = RATE / 50 * 2   // 20 ms, 16 bit mono → 1920 bayt
        const val CONTENT_TYPE = "audio/pcm; format=s16le; rate=48000; channels=1"
    }
}
