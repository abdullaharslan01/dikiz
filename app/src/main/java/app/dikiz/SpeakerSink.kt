package app.dikiz

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.InputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * Mac'in sesi → telefon hoparlörü (POST /<kod>/speaker).
 * Gövde: ham PCM, 16 bit işaretli little-endian, stereo, 48 kHz; bağlantı kapanana kadar sürer.
 * Aynı anda tek gönderen: yeni bağlanan eskisinin yerini alır.
 */
class SpeakerSink {
    val playing = MutableStateFlow(false)
    private val generation = AtomicLong()

    /** Bu iş parçacığında, bağlantı kapanana (ya da yeni gönderen gelene) kadar çalar. */
    fun play(input: InputStream) {
        val me = generation.incrementAndGet()
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(min, PREBUFFER * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        playing.value = true
        val buf = ByteArray(3840)          // 20 ms
        var carry = 0                      // 4 baytlık kareye hizalama
        var written = 0
        var started = false
        try {
            while (generation.get() == me) {
                // Gecikme birikmesin: ağda 300 ms'den fazla ses beklerse fazlasını atla (100 ms kalsın)
                val avail = runCatching { input.available() }.getOrDefault(0)
                if (carry == 0 && avail > MAX_LAG) {
                    var skip = (avail - KEEP).toLong()
                    skip -= skip % 4
                    while (skip > 0) { val k = input.skip(skip); if (k <= 0) break; skip -= k }
                }
                val n = input.read(buf, carry, buf.size - carry)
                if (n <= 0) break
                val total = carry + n
                val whole = total - (total % 4)
                if (whole > 0) {
                    track.write(buf, 0, whole)   // dolunca bekler: gönderen kendiliğinden yavaşlar
                    written += whole
                }
                carry = total - whole
                if (carry > 0) System.arraycopy(buf, whole, buf, 0, carry)
                // ~120 ms birikince çalmaya başla (kısa kesintilerde takılmasın)
                if (!started && written >= PREBUFFER) { track.play(); started = true }
            }
        } finally {
            runCatching { track.stop() }
            track.release()
            if (generation.get() == me) playing.value = false
        }
    }

    companion object {
        const val RATE = 48000
        const val PREBUFFER = RATE * 4 * 120 / 1000   // 120 ms stereo 16 bit
        const val MAX_LAG = RATE * 4 * 300 / 1000
        const val KEEP = RATE * 4 * 100 / 1000
    }
}
