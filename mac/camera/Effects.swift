// Dikiz Kamera görüntü hattı: yön → kadraj → güzelleştirme → filtre → arka plan bulanıklığı.
// Hepsi cihaz üzerinde: CoreImage (GPU) + Apple Vision (yüz ve kişi algılama).

import Foundation
import CoreImage
import CoreGraphics
import Vision

struct CamConfig: Equatable {
    var mirror = false
    var flip = false
    var rot = 0
    var blur = false        // arka planı bulanıklaştır
    var beauty = false      // güzelleştirme (yalnızca yüz)
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
            case "blur": c.blur = v == "1"
            case "beauty": c.beauty = v == "1"
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
    private let maskContext = CIContext(options: [.cacheIntermediates: false])

    // Vision sonuçları (çıkış W×H koordinatlarında)
    private var faces: [CGRect] = []
    private var facesAt = Date.distantPast
    private var mask: CIImage?            // yumuşatılmış kişi maskesi
    private var faceBusy = false
    private var maskBusy = false
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

        // 2) Kadraj: yataysa doldur, dikse sığdır + aynı karenin bulanık hâli arka planda
        var out: CIImage
        let aspect = W / H
        if abs(ext.width / ext.height - aspect) < 0.25 {
            var cw = ext.width, ch = ext.width / aspect
            if ch > ext.height { ch = ext.height; cw = ch * aspect }
            let c = CGRect(x: (ext.width - cw) / 2, y: (ext.height - ch) / 2, width: cw, height: ch)
            let s = W / cw
            out = img.cropped(to: c)
                .transformed(by: CGAffineTransform(translationX: -c.minX, y: -c.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .cropped(to: outRect)
        } else {
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

        // 3) Vision: kişi maskesi (bulanıklık) ve yüz konumu (güzelleştirme)
        if cfg.blur { updateMask(from: out) } else { clearMask() }
        if cfg.beauty { detectFaces(in: out) }

        // 4) Güzelleştirme: yalnızca yüz bölgesinde, kenarları koruyarak yumuşatma
        if cfg.beauty, let faceMask = currentFaceMask(outRect: outRect) {
            out = beautify(out, faceMask: faceMask, outRect: outRect)
        }

        // 5) Filtre
        out = applyFilter(cfg.filter, to: out)

        // 6) Arka planı bulanıklaştır: kişi keskin kalır, arka plan yumuşak ve hafif sönük
        if cfg.blur, let m = currentMask() {
            let bg = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9, kCIInputBrightnessKey: -0.03])
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

    // MARK: güzelleştirme

    /// Cilt yumuşatma: güçlü bulanık katman, keskin kenarlarda (göz, kaş, saç, ağız) azaltılır;
    /// yalnızca yüzün etrafındaki yumuşak elips maskede uygulanır. Ardından hafif ışıltı ve sıcaklık.
    private func beautify(_ img: CIImage, faceMask: CIImage, outRect: CGRect) -> CIImage {
        let smooth = img.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
            .cropped(to: outRect)
        // Kenar haritası: detay olan yerde yumuşatma azalır (gözler ve kaşlar net kalır)
        let edges = img.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])
            .cropped(to: outRect)
        let keepDetail = edges.applyingFilter("CIColorInvert")
        // Yüz maskesi × detaysız bölge × %70 güç
        let strength = keepDetail.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: faceMask])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.7, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0),
            ])
        var out = smooth.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: strength])
        // Yüzde hafif ışıltı ve sıcaklık
        let glow = out.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.035, kCIInputSaturationKey: 1.04])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6100, y: 0)])
        out = glow.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: faceMask])
        return out
    }

    /// Algılanan yüzlerin etrafında yumuşak kenarlı elips maske (beyaz = yüz).
    private func currentFaceMask(outRect: CGRect) -> CIImage? {
        lock.lock(); let fs = faces; let at = facesAt; lock.unlock()
        guard !fs.isEmpty, Date().timeIntervalSince(at) < 1.5 else { return nil }
        var mask = CIImage(color: .black).cropped(to: outRect)
        for f in fs {
            let center = CIVector(x: f.midX, y: f.midY + f.height * 0.05)
            let r = max(f.width, f.height) * 0.62
            let spot = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center, "inputRadius0": r * 0.75, "inputRadius1": r * 1.15,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!.cropped(to: outRect)
            mask = spot.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: mask])
        }
        return mask
    }

    // MARK: Vision

    private func detectFaces(in out: CIImage) {
        guard frameNo % 3 == 0 else { return }
        lock.lock(); if faceBusy { lock.unlock(); return }; faceBusy = true; lock.unlock()
        let ext = out.extent
        let small = out.transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
        visionQueue.async { [weak self] in
            guard let self else { return }
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(ciImage: small, options: [:]).perform([req])
            let rects = (req.results ?? []).map {
                CGRect(x: $0.boundingBox.minX * ext.width, y: $0.boundingBox.minY * ext.height,
                       width: $0.boundingBox.width * ext.width, height: $0.boundingBox.height * ext.height)
            }
            self.lock.lock()
            if !rects.isEmpty { self.faces = rects; self.facesAt = Date() }
            self.faceBusy = false
            self.lock.unlock()
        }
    }

    /// Kişi maskesi: Vision ile çıkarılır, kenarı yumuşatılır ve bir önceki maskeyle
    /// harmanlanarak titremesi azaltılır.
    private func updateMask(from out: CIImage) {
        guard frameNo % 2 == 0 else { return }
        lock.lock(); if maskBusy { lock.unlock(); return }; maskBusy = true; let prev = mask; lock.unlock()
        let ext = out.extent
        let small = out.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        visionQueue.async { [weak self] in
            guard let self else { return }
            try? VNImageRequestHandler(ciImage: small, options: [:]).perform([self.segmentation])
            var result: CIImage?
            if let pb = self.segmentation.results?.first?.pixelBuffer {
                let mi = CIImage(cvPixelBuffer: pb)
                var m = mi.transformed(by: CGAffineTransform(scaleX: ext.width / mi.extent.width, y: ext.height / mi.extent.height))
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.5])   // yumuşak kenar
                    .cropped(to: ext)
                if let prev {
                    m = m.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: prev, kCIInputTimeKey: 0.35])               // zamanla yumuşatma
                }
                // Zincir uzamasın: küçük bir bitmap'e çiz, bir sonraki karede onu kullan
                if let cg = self.maskContext.createCGImage(m, from: ext, format: .L8, colorSpace: nil) {
                    result = CIImage(cgImage: cg)
                }
            }
            self.lock.lock()
            if let result { self.mask = result }
            self.maskBusy = false
            self.lock.unlock()
        }
    }

    private func clearMask() { lock.lock(); mask = nil; lock.unlock() }
    private func currentMask() -> CIImage? { lock.lock(); defer { lock.unlock() }; return mask }

    // MARK: filtreler

    private func applyFilter(_ name: String, to i: CIImage) -> CIImage {
        switch name {
        case "warm":
            return i.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5400, y: 0)])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
        case "cool":
            return i.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7600, y: 0)])
        case "vivid":
            return i.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.5])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.05])
        case "mono":
            return i.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08])
        case "cinema":
            return i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.1])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6900, y: 10)])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.5, kCIInputRadiusKey: 1.6])
        default:
            return i
        }
    }
}
