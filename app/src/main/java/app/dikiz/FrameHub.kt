package app.dikiz

import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicInteger

/** Kamera iş parçacığı ile HTTP istemcileri arasında en son JPEG karesini paylaşır. */
class FrameHub {
    class Frame(val seq: Long, val jpeg: ByteArray, val width: Int, val height: Int, val rotation: Int)

    private val lock = Object()
    private var seq = 0L

    @Volatile
    var latest: Frame? = null
        private set

    private val streamClients = AtomicInteger()
    val clientCount = MutableStateFlow(0)

    @Volatile
    private var demandUntil = 0L

    /** Kodlamayı yalnızca birisi izliyorsa yap (pil ve ısı için). */
    fun wantsFrames(): Boolean =
        streamClients.get() > 0 || SystemClock.elapsedRealtime() < demandUntil

    fun requestFramesFor(ms: Long) {
        demandUntil = SystemClock.elapsedRealtime() + ms
    }

    fun clientJoined() { clientCount.value = streamClients.incrementAndGet() }
    fun clientLeft() { clientCount.value = streamClients.decrementAndGet() }

    fun publish(jpeg: ByteArray, width: Int, height: Int, rotation: Int) {
        synchronized(lock) {
            seq++
            latest = Frame(seq, jpeg, width, height, rotation)
            lock.notifyAll()
        }
    }

    /** [afterSeq]'den daha yeni bir kare gelene kadar bekler; zaman aşımında null döner. */
    fun awaitAfter(afterSeq: Long, timeoutMs: Long): Frame? {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        synchronized(lock) {
            while ((latest?.seq ?: 0L) <= afterSeq) {
                val remaining = end - SystemClock.elapsedRealtime()
                if (remaining <= 0) return null
                lock.wait(remaining)
            }
            return latest
        }
    }
}
