package app.dikiz

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import androidx.camera.core.ImageProxy
import java.io.ByteArrayOutputStream

/** YUV_420_888 kareyi NV21'e çevirip JPEG olarak sıkıştırır. Tek iş parçacığından çağrılmalı. */
class JpegEncoder {
    private var nv21 = ByteArray(0)
    private var rowU = ByteArray(0)
    private var rowV = ByteArray(0)
    private val out = ByteArrayOutputStream(512 * 1024)

    fun encode(image: ImageProxy, quality: Int): ByteArray {
        val w = image.width
        val h = image.height
        val size = w * h + 2 * ((w + 1) / 2) * ((h + 1) / 2)
        if (nv21.size != size) nv21 = ByteArray(size)

        // --- Y düzlemi ---
        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer
        val yRow = yPlane.rowStride
        var pos = 0
        if (yRow == w && yPlane.pixelStride == 1) {
            yBuf.position(0)
            yBuf.get(nv21, 0, w * h)
            pos = w * h
        } else {
            for (row in 0 until h) {
                yBuf.position(row * yRow)
                yBuf.get(nv21, pos, w)
                pos += w
            }
        }

        // --- VU (NV21) iç içe ---
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val uvRow = vPlane.rowStride
        val uvPix = vPlane.pixelStride
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val rowLen = (cw - 1) * uvPix + 1
        if (rowU.size < rowLen) { rowU = ByteArray(rowLen); rowV = ByteArray(rowLen) }
        for (row in 0 until ch) {
            val start = row * uvRow
            val len = minOf(rowLen, vBuf.limit() - start, uBuf.limit() - start)
            vBuf.position(start); vBuf.get(rowV, 0, len)
            uBuf.position(start); uBuf.get(rowU, 0, len)
            var i = 0
            for (col in 0 until cw) {
                nv21[pos++] = rowV[i]
                nv21[pos++] = rowU[i]
                i += uvPix
            }
        }

        out.reset()
        YuvImage(nv21, ImageFormat.NV21, w, h, null)
            .compressToJpeg(Rect(0, 0, w, h), quality, out)
        return out.toByteArray()
    }
}
