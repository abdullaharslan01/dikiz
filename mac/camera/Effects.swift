// Dikiz Kamera görüntü hattı: yön → kadraj (yüz takibi) → ışık → güzelleştirme → filtre → arka plan bulanıklığı.
// Hepsi cihaz üzerinde: CoreImage (GPU) + Apple Vision (yüz ve kişi algılama).

import Foundation
import CoreImage
import CoreGraphics
import Vision

struct CamConfig: Equatable {
    var mirror = false
    var flip = false
    var rot = 0
    var follow = false      // beni takip et (otomatik kadraj)
    var blur = false        // arka planı bulanıklaştır
    var beauty = false      // güzelleştirme
    var light = false       // ışığı düzelt
    var filter = "none"     // none | warm | cool | vivid | mono | cinema

    static func parse(_ s: String) -> CamConfig {
        var c = CamConfig()
        for kv in s.split(separator: ";") {
            let p = kv.split(separator: "=", maxSplits: 1)
            guard p.count == 2 else { continue }
            let v = String(p[1])
            switch p[0] {
            case "mirror": c.mirror = v == "1"
            case "flip": c.flip = v == "1"
            case "rot": c.rot = Int(v) ?? 0
            case "follow": c.follow = v == "1"
            case "blur": c.blur = v == "1"
            case "beauty": c.beauty = v == "1"
            case "light": c.light = v == "1"
            case "filter": c.filter = v
            default: break
            }
        }
        return c
    }
}

final class VideoPipeline {
    let size: CGSize
    private let visionQueue = DispatchQueue(label: "dikiz.vision", qos: .userInitiated)
    private let lock = NSLock()

    // Vision sonuçları (vision kuyruğunda yazılır, kilitle okunur)
    private var faceBox: CGRect?          // yönlendirilmiş görüntü koordinatlarında
    private var faceAt = Date.distantPast
    private var mask: CIImage?            // çıkış (W×H) koordinatlarında kişi maskesi
    private var faceBusy = false
    private var maskBusy = false

    private var crop: CGRect?             // yumuşatılmış kadraj
    private var frameNo = 0

    private lazy var segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    init(size: CGSize) { self.size = size }

    func render(_ image: CGImage, rotation: Int, cfg: CamConfig) -> CIImage {
        frameNo += 1
        let W = size.width, H = size.height
        let outRect = CGRect(origin: .zero, size: size)

        // 1) Yön: telefonun duruşu + menüdeki döndürme, ardından ayna / ters çevirme
        var img = CIImage(cgImage: image).oriented(orientation(rotation + cfg.rot))
        img = normalized(img)
        if cfg.mirror { img = normalized(img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if cfg.flip { img = normalized(img.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        let ext = img.extent

        // 2) Kadraj
        if cfg.follow { detectFace(in: img) }
        let target = targetRegion(ext: ext, follow: cfg.follow)
        var out: CIImage
        if let target {
            let c = smooth(toward: target)
            let s = W / c.width
            out = img.cropped(to: c)
                .transformed(by: CGAffineTransform(translationX: -c.minX, y: -c.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .cropped(to: outRect)
        } else {
            // Telefon dik ve takip kapalı: sığdır + aynı karenin bulanık hâli arka planda
            crop = nil
            let fit = min(W / ext.width, H / ext.height)
            let fill = max(W / ext.width, H / ext.height) * 1.1
            let fg = img.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            let fgOff = fg.transformed(by: CGAffineTransform(translationX: (W - fg.extent.width) / 2, y: (H - fg.extent.height) / 2))
            let bg = img.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let bgOff = bg.transformed(by: CGAffineTransform(translationX: (W - bg.extent.width) / 2, y: (H - bg.extent.height) / 2))
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.2])
                .cropped(to: outRect)
            out = fgOff.composited(over: bgOff)
        }

        // 3) Kişi maskesi (arka plan bulanıklığı ve güzelleştirme için)
        if cfg.blur || cfg.beauty { updateMask(from: out) } else { setMask(nil) }
        let m = currentMask()

        // 4) Işığı düzelt: gölgeleri aç, hafif pozlama
        if cfg.light {
            out = out.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.75, "inputHighlightAmount": 0.95])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.18])
        }

        // 5) Güzelleştirme: cildi yumuşat (yalnızca kişide), biraz canlılık
        if cfg.beauty {
            let soft = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.2])
                .cropped(to: outRect)
            let softHalf = soft.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
            var smoothed = softHalf.composited(over: out)
            smoothed = smoothed.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.02, kCIInputSaturationKey: 1.06, kCIInputContrastKey: 1.0,
            ])
            if let m {
                out = smoothed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
            } else {
                out = smoothed
            }
        }

        // 6) Filtre
        out = applyFilter(cfg.filter, to: out)

        // 7) Arka planı bulanıklaştır
        if cfg.blur, let m {
            let bg = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
                .cropped(to: outRect)
            out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m])
        }

        return out.cropped(to: outRect).composited(over: CIImage(color: .black).cropped(to: outRect))
    }

    // MARK: yön

    private func orientation(_ deg: Int) -> CGImagePropertyOrientation {
        switch ((deg % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    private func normalized(_ i: CIImage) -> CIImage {
        i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
    }

    // MARK: kadraj

    /// Çıkışın en-boy oranında kırpılacak bölge; nil = sığdır (telefon dik, takip kapalı).
    private func targetRegion(ext: CGRect, follow: Bool) -> CGRect? {
        let aspect = size.width / size.height
        // Kareye sığan en büyük 16:9 bölge
        var fullW = ext.width, fullH = ext.width / aspect
        if fullH > ext.height { fullH = ext.height; fullW = fullH * aspect }
        let full = CGRect(x: ext.midX - fullW / 2, y: ext.midY - fullH / 2, width: fullW, height: fullH)

        if follow {
            lock.lock(); let f = faceBox; let at = faceAt; lock.unlock()
            if let f, Date().timeIntervalSince(at) < 2.0 {
                // Baş + omuzlar: yüz yüksekliğinin ~3.4 katı, yüz kadrajın üst üçte birinde
                var h = min(max(f.height * 3.4, ext.height * 0.35), fullH)
                var w = h * aspect
                if w > fullW { w = fullW; h = w / aspect }
                var r = CGRect(x: f.midX - w / 2, y: f.midY - h * 0.62, width: w, height: h)
                r.origin.x = min(max(r.minX, ext.minX), ext.maxX - w)
                r.origin.y = min(max(r.minY, ext.minY), ext.maxY - h)
                return r
            }
            return full
        }
        // Takip kapalı: görüntü zaten yataysa doldur, dikse sığdır
        let close = abs(ext.width / ext.height - aspect) < 0.25
        return close ? full : nil
    }

    private func smooth(toward t: CGRect) -> CGRect {
        guard let c = crop, abs(c.width - t.width) < t.width * 3 else { crop = t; return t }
        let k: CGFloat = 0.10
        let n = CGRect(x: c.minX + (t.minX - c.minX) * k, y: c.minY + (t.minY - c.minY) * k,
                       width: c.width + (t.width - c.width) * k, height: c.height + (t.height - c.height) * k)
        crop = n
        return n
    }

    // MARK: Vision

    private func detectFace(in img: CIImage) {
        guard frameNo % 4 == 0 else { return }
        lock.lock(); if faceBusy { lock.unlock(); return }; faceBusy = true; lock.unlock()
        let ext = img.extent
        let small = img.transformed(by: CGAffineTransform(scaleX: 0.35, y: 0.35))
        visionQueue.async { [weak self] in
            guard let self else { return }
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(ciImage: small, options: [:]).perform([req])
            let faces = (req.results ?? []).map { $0.boundingBox }
            var box: CGRect?
            if let biggest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                // En büyük yüz + ona yakın diğer yüzler (iki kişi de kadraja girsin)
                var u = biggest
                for f in faces where f.height > biggest.height * 0.6 { u = u.union(f) }
                box = CGRect(x: ext.minX + u.minX * ext.width, y: ext.minY + u.minY * ext.height,
                             width: u.width * ext.width, height: u.height * ext.height)
            }
            self.lock.lock()
            if let box { self.faceBox = box; self.faceAt = Date() }
            self.faceBusy = false
            self.lock.unlock()
        }
    }

    private func updateMask(from out: CIImage) {
        guard frameNo % 2 == 0 else { return }
        lock.lock(); if maskBusy { lock.unlock(); return }; maskBusy = true; lock.unlock()
        let ext = out.extent
        let small = out.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        visionQueue.async { [weak self] in
            guard let self else { return }
            let handler = VNImageRequestHandler(ciImage: small, options: [:])
            try? handler.perform([self.segmentation])
            var m: CIImage?
            if let pb = self.segmentation.results?.first?.pixelBuffer {
                let mi = CIImage(cvPixelBuffer: pb)
                m = mi.transformed(by: CGAffineTransform(scaleX: ext.width / mi.extent.width, y: ext.height / mi.extent.height))
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])   // yumuşak kenar
                    .cropped(to: ext)
            }
            self.lock.lock()
            if m != nil { self.mask = m }
            self.maskBusy = false
            self.lock.unlock()
        }
    }

    private func setMask(_ m: CIImage?) { lock.lock(); mask = m; lock.unlock() }
    private func currentMask() -> CIImage? { lock.lock(); defer { lock.unlock() }; return mask }

    // MARK: filtreler

    private func applyFilter(_ name: String, to i: CIImage) -> CIImage {
        switch name {
        case "warm":
            return i.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 0)])
        case "cool":
            return i.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8000, y: 0)])
        case "vivid":
            return i.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.06])
        case "mono":
            return i.applyingFilter("CIPhotoEffectNoir")
        case "cinema":
            return i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.12])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.6, kCIInputRadiusKey: 1.4])
        default:
            return i
        }
    }
}
