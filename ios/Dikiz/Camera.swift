import AVFoundation
import CoreImage
import CoreMotion
import UIKit

/// Arka kamera → JPEG kareler (Android CameraController karşılığı).
///
/// Kareler telefonun duruşuna göre döndürülüp düz gönderilir, bu yüzden izleme sayfasına
/// "rotation: 0" bildirilir. iOS, uygulama arka plana geçince ya da ekran kilitlenince
/// kamerayı durdurur: yayın sürsün diye ekran açık tutulur ve "Karart" sunulur.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Arayüzün gösterdiği durum (ana iş parçacığında güncellenir).
    struct UIState: Equatable {
        var width = 0
        var height = 0
        var fps: Double = 0
        var zoom: Double = 1
        var lensStops: [Double] = [1]
        var hasFlash = false
        var torch = false
        var phonePreview = true
        var error: String?
    }

    @Published private(set) var ui = UIState()

    let session = AVCaptureSession()
    private let hub: FrameHub
    private let sessionQueue = DispatchQueue(label: "dikiz.camera.session")
    private let videoQueue = DispatchQueue(label: "dikiz.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let motion = CMMotionManager()
    private let prefs = UserDefaults.standard
    private var configured = false

    // ---- iş parçacıkları arası durum (lock ile) ----
    private let lock = NSLock()
    private var s = Snapshot()

    private struct Snapshot {
        var width = 0, height = 0
        var rotationAngle: CGFloat = 90
        var wideFactor: CGFloat = 1        // "1×" (ana kamera) için gerçek yakınlaştırma çarpanı
        var zoom: Double = 1               // kullanıcıya görünen (ana kamera = 1)
        var zoomMin: Double = 1, zoomMax: Double = 1
        var lensStops: [Double] = [1]
        var hasFlash = false, torch = false
        var evMin = 0, evMax = 0, ev = 0
        var evStep: Double = 0.5
        var quality = 80
        var maxFps = 30
        var fps: Double = 0
        var phonePreview = true
        var focusLocked = false
        var manualFocus: Double?
        var aeLock = false, awbLock = false
        var hq = true
        var preset = "1280x720"
        var fov: Double = 0
        var error: String?
    }

    private var frameCount = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var lastPublish: CFTimeInterval = 0

    static let presets: [(String, AVCaptureSession.Preset)] = [
        ("1920x1080", .hd1920x1080), ("1280x720", .hd1280x720), ("640x480", .vga640x480),
    ]

    init(hub: FrameHub) {
        self.hub = hub
        super.init()
        lock.lock()
        s.quality = prefs.object(forKey: "quality") as? Int ?? 80
        s.maxFps = prefs.object(forKey: "maxFps") as? Int ?? 30
        s.preset = prefs.string(forKey: "size") ?? "1280x720"
        s.hq = prefs.object(forKey: "hq") as? Bool ?? true
        s.phonePreview = prefs.object(forKey: "phonePreview") as? Bool ?? true
        lock.unlock()
    }

    // MARK: - Başlat / durdur

    func start() {
        sessionQueue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.startMotion() }
        }
    }

    func stop() {
        DispatchQueue.main.async { self.motion.stopDeviceMotionUpdates() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        guard let dev = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
            .devices.first,
            let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input)
        else {
            setError("Kamera açılamadı")
            return
        }
        device = dev
        session.addInput(input)

        let preset = Self.presets.first { $0.0 == currentPreset() }?.1 ?? .hd1280x720
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .hd1280x720

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        applyRotation(90)

        // Lensler: sanal cihazda 1.0 = en geniş lens. "1×" ana (geniş) kamera olsun diye ölçekleriz.
        let constituents = dev.constituentDevices.map(\.deviceType)
        let switches = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltra = constituents.contains(.builtInUltraWideCamera)
        let hasTele = constituents.contains(.builtInTelephotoCamera)
        let wide: CGFloat = hasUltra ? (switches.first ?? 1) : 1
        var stops: [Double] = []
        if hasUltra { stops.append(round1(Double(dev.minAvailableVideoZoomFactor / wide))) }
        stops.append(1)
        if hasTele, let t = switches.last, t > wide { stops.append(round1(Double(t / wide))) }

        let saved = prefs.object(forKey: "zoom") as? Double ?? 1
        let zMin = Double(dev.minAvailableVideoZoomFactor / wide)
        let zMax = Double(min(dev.maxAvailableVideoZoomFactor, wide * 10) / wide)
        let z = min(max(saved, zMin), zMax)
        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = CGFloat(z) * wide
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }

        lock.lock()
        s.wideFactor = wide
        s.lensStops = stops
        s.zoomMin = zMin; s.zoomMax = zMax; s.zoom = z
        s.hasFlash = dev.hasTorch
        s.evStep = 0.5
        s.evMin = max(-6, Int((dev.minExposureTargetBias / 0.5).rounded(.up)))
        s.evMax = min(6, Int((dev.maxExposureTargetBias / 0.5).rounded(.down)))
        s.fov = Double(dev.activeFormat.videoFieldOfView)
        s.error = nil
        lock.unlock()
        publishUI()
    }

    private func currentPreset() -> String { lock.lock(); defer { lock.unlock() }; return s.preset }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private func setError(_ e: String) {
        lock.lock(); s.error = e; lock.unlock()
        publishUI()
    }

    // MARK: - Duruş (telefon dik / yatay / ters) → kare döndürme

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            // Yatay masada (z baskın) yön değişmesin; köşe bölgelerinde titremesin.
            guard abs(g.z) < 0.8 else { return }
            var angle: CGFloat?
            if g.y < -0.6 { angle = 90 }          // dik
            else if g.y > 0.6 { angle = 270 }     // baş aşağı
            else if g.x < -0.6 { angle = 0 }      // üstü sola
            else if g.x > 0.6 { angle = 180 }     // üstü sağa
            guard let a = angle else { return }
            self.lock.lock()
            let changed = self.s.rotationAngle != a
            self.s.rotationAngle = a
            self.lock.unlock()
            if changed { self.sessionQueue.async { self.applyRotation(a) } }
        }
    }

    private func applyRotation(_ a: CGFloat) {
        guard let c = output.connection(with: .video), c.isVideoRotationAngleSupported(a) else { return }
        c.videoRotationAngle = a
    }

    // MARK: - Kareler

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let now = CACurrentMediaTime()

        frameCount += 1
        var fpsChanged = false
        lock.lock()
        if now - fpsWindowStart >= 1 {
            s.fps = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
            fpsChanged = true
        }
        let sizeChanged = s.width != w || s.height != h
        s.width = w; s.height = h
        let quality = s.quality, maxFps = s.maxFps
        lock.unlock()
        if fpsChanged || sizeChanged { publishUI() }

        guard hub.wantsFrames() else { return }
        if now - lastPublish < 1.0 / Double(max(1, maxFps)) - 0.004 { return }
        lastPublish = now

        let img = CIImage(cvPixelBuffer: pb)
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(quality) / 100,
        ]
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: img, colorSpace: cs, options: opts) else { return }
        hub.publish(jpeg: jpeg, width: w, height: h)
    }

    // MARK: - Ayarlar (izleme sayfası ve Mac menüsü: /api/set?k=v)

    func set(_ key: String, _ value: String) {
        sessionQueue.async { self.apply(key, value) }
    }

    private func withDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        body(d)
        d.unlockForConfiguration()
    }

    private func apply(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "zoom":
            guard let z = Double(value) else { break }
            lock.lock()
            let zz = min(max(z, s.zoomMin), s.zoomMax)
            s.zoom = zz
            let wide = s.wideFactor
            lock.unlock()
            prefs.set(zz, forKey: "zoom")
            withDevice { $0.videoZoomFactor = CGFloat(zz) * wide }
        case "torch":
            withDevice { d in
                guard d.hasTorch else { return }
                if on { try? d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } else { d.torchMode = .off }
            }
            lock.lock(); s.torch = on && (device?.hasTorch ?? false); lock.unlock()
        case "ev":
            guard let e = Int(value) else { break }
            lock.lock()
            let ee = min(max(e, s.evMin), s.evMax)
            s.ev = ee
            let bias = Float(Double(ee) * s.evStep)
            lock.unlock()
            withDevice { $0.setExposureTargetBias(bias, completionHandler: nil) }
        case "quality":
            guard let q = Int(value) else { break }
            let qq = min(max(q, 30), 100)
            prefs.set(qq, forKey: "quality")
            lock.lock(); s.quality = qq; lock.unlock()
        case "fps":
            guard let f = Int(value) else { break }
            let ff = min(max(f, 1), 30)
            prefs.set(ff, forKey: "maxFps")
            lock.lock(); s.maxFps = ff; lock.unlock()
        case "size":
            guard let p = Self.presets.first(where: { $0.0 == value }), session.canSetSessionPreset(p.1) else { break }
            prefs.set(p.0, forKey: "size")
            lock.lock(); s.preset = p.0; lock.unlock()
            session.beginConfiguration()
            session.sessionPreset = p.1
            session.commitConfiguration()
            lock.lock(); let a = s.rotationAngle; lock.unlock()
            applyRotation(a)
        case "preview":
            prefs.set(on, forKey: "phonePreview")
            lock.lock(); s.phonePreview = on; lock.unlock()
        case "hq":
            prefs.set(on, forKey: "hq")
            lock.lock(); s.hq = on; lock.unlock()
        case "aelock":
            withDevice { d in
                let m: AVCaptureDevice.ExposureMode = on ? .locked : .continuousAutoExposure
                if d.isExposureModeSupported(m) { d.exposureMode = m }
            }
            lock.lock(); s.aeLock = on; lock.unlock()
        case "awblock":
            withDevice { d in
                let m: AVCaptureDevice.WhiteBalanceMode = on ? .locked : .continuousAutoWhiteBalance
                if d.isWhiteBalanceModeSupported(m) { d.whiteBalanceMode = m }
            }
            lock.lock(); s.awbLock = on; lock.unlock()
        case "focus":
            // Görüntüdeki (düz çevrilmiş karedeki) nokta → algılayıcı koordinatı.
            let parts = value.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { break }
            let x = min(max(parts[0], 0), 1), y = min(max(parts[1], 0), 1)
            lock.lock(); let a = s.rotationAngle; lock.unlock()
            let p: CGPoint
            switch a {
            case 90: p = CGPoint(x: y, y: 1 - x)
            case 180: p = CGPoint(x: 1 - x, y: 1 - y)
            case 270: p = CGPoint(x: 1 - y, y: x)
            default: p = CGPoint(x: x, y: y)
            }
            withDevice { d in
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
                if d.isExposureModeSupported(.autoExpose) { d.exposureMode = .autoExpose }
            }
            lock.lock(); s.focusLocked = true; s.manualFocus = nil; lock.unlock()
        case "autofocus":
            withDevice { d in
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
            lock.lock(); s.focusLocked = false; s.manualFocus = nil; lock.unlock()
        case "focusDist":
            // Android ile aynı ölçek: 0 = sonsuz, 10 = en yakın. iOS'ta lensPosition 0 = en yakın.
            if let dv = Double(value) {
                let d = min(max(dv, 0), 10)
                withDevice { dev in
                    if dev.isLockingFocusWithCustomLensPositionSupported {
                        dev.setFocusModeLocked(lensPosition: Float(1 - d / 10), completionHandler: nil)
                    }
                }
                lock.lock(); s.manualFocus = d; s.focusLocked = false; lock.unlock()
            } else {
                apply("autofocus", "1")
            }
        default:
            break
        }
        publishUI()
    }

    // MARK: - Durum

    private func publishUI() {
        lock.lock()
        let u = UIState(width: s.width, height: s.height, fps: s.fps, zoom: s.zoom, lensStops: s.lensStops,
                        hasFlash: s.hasFlash, torch: s.torch, phonePreview: s.phonePreview, error: s.error)
        lock.unlock()
        DispatchQueue.main.async { if self.ui != u { self.ui = u } }
    }

    /// Android'deki /api/state ile aynı anahtarlar (izleme sayfası ve Mac menüsü bunları okur).
    func stateJSON(clients: Int) -> Data {
        lock.lock()
        let x = s
        lock.unlock()
        let dict: [String: Any] = [
            "cameras": [["id": "0", "label": "Arka kamera", "fov": x.fov]],
            "cameraId": "0",
            "sizes": Self.presets.map(\.0),
            "targetSize": x.preset,
            "width": x.width,
            "height": x.height,
            "rotation": 0,
            "zoomMin": x.zoomMin,
            "zoomMax": x.zoomMax,
            "zoom": x.zoom,
            "hasFlash": x.hasFlash,
            "torch": x.torch,
            "evMin": x.evMin,
            "evMax": x.evMax,
            "ev": x.ev,
            "evStep": x.evStep,
            "quality": x.quality,
            "maxFps": x.maxFps,
            "fps": x.fps,
            "phonePreview": x.phonePreview,
            "focusLocked": x.focusLocked,
            "lensStops": x.lensStops,
            "minFocusDiopter": 10.0,
            "manualFocus": x.manualFocus as Any? ?? NSNull(),
            "aeLock": x.aeLock,
            "awbLock": x.awbLock,
            "hq": x.hq,
            "supports60": false,
            "clients": clients,
            "error": x.error as Any? ?? NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }
}
