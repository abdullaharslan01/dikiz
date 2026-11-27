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
        var zoomMin: Double = 1
        var zoomMax: Double = 1
        var hasFlash = false
        var torch = false
        var phonePreview = true
        var isFront = false
        var canSwitch = false
        var error: String?
    }

    @Published private(set) var ui = UIState()

    let session = AVCaptureSession()
    private let hub: FrameHub
    private let sessionQueue = DispatchQueue(label: "dikiz.camera.session")
    private let videoQueue = DispatchQueue(label: "dikiz.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
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
        var front = false
        var hasFront = false
        var error: String?
    }

    private var frameCount = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var lastPublish: CFTimeInterval = 0

    static let presets: [(String, AVCaptureSession.Preset)] = [
        ("1920x1080", .hd1920x1080), ("1280x720", .hd1280x720), ("640x480", .vga640x480),
        ("352x288", .cif352x288),
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
        s.front = prefs.string(forKey: "position") == "front"
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
        let preset = Self.presets.first { $0.0 == currentPreset() }?.1 ?? .hd1280x720
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .hd1280x720
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let hasFront = Self.frontDevice() != nil
        lock.lock(); s.hasFront = hasFront; let front = s.front && hasFront; lock.unlock()
        setupInput(front: front)
    }

    /// Arka: Kamera uygulaması gibi tüm lensleri kapsayan sanal cihaz (0.5× / 1× / 2× / 3× ya da 5×).
    private static func backDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back
        ).devices.first
    }

    private static func frontDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera], mediaType: .video, position: .front
        ).devices.first
    }

    /// Ön ↔ arka geçişi: girdiyi değiştirir, lens adımlarını yeniden hesaplar.
    private func setupInput(front: Bool) {
        guard let dev = front ? Self.frontDevice() : Self.backDevice(),
              let newInput = try? AVCaptureDeviceInput(device: dev) else {
            setError("Kamera açılamadı")
            return
        }
        // Işık yalnızca arka kamerada; geçerken kapat.
        if let old = device, old.hasTorch, old.torchMode != .off, (try? old.lockForConfiguration()) != nil {
            old.torchMode = .off
            old.unlockForConfiguration()
        }
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        guard session.canAddInput(newInput) else {
            if let old = input, session.canAddInput(old) { session.addInput(old) }
            session.commitConfiguration()
            setError("Kamera açılamadı")
            return
        }
        session.addInput(newInput)
        input = newInput
        device = dev
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = front      // ön kamera ayna gibi (görüntülü görüşme alışkanlığı)
        }
        session.commitConfiguration()
        lock.lock(); let a = s.rotationAngle; lock.unlock()
        applyRotation(a)

        // Lensler: sanal cihazda 1.0 = en geniş lens. "1×" ana (geniş) kamera olsun diye ölçekleriz.
        let constituents = dev.constituentDevices.map(\.deviceType)
        let switches = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltra = constituents.contains(.builtInUltraWideCamera)
        let hasTele = constituents.contains(.builtInTelephotoCamera)
        let wide: CGFloat = hasUltra ? (switches.first ?? 1) : 1
        let zMin = Double(dev.minAvailableVideoZoomFactor / wide)
        let zMax = Double(min(dev.maxAvailableVideoZoomFactor, wide * 15) / wide)
        var stops: [Double] = []
        if hasUltra { stops.append(round1(zMin)) }
        stops.append(1)
        let tele: Double? = (hasTele && (switches.last ?? 0) > wide) ? round1(Double(switches.last! / wide)) : nil
        // 2×: Kamera uygulamasındaki gibi ana kameranın ortası (telefoto 2× değilse)
        if !front, zMax >= 2, tele != 2 { stops.append(2) }
        if let t = tele { stops.append(t) }
        stops = Array(Set(stops)).sorted()

        let key = front ? "zoomFront" : "zoom"
        let saved = prefs.object(forKey: key) as? Double ?? 1
        let z = min(max(saved, zMin), zMax)
        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = CGFloat(z) * wide
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }

        lock.lock()
        s.front = front
        s.wideFactor = wide
        s.lensStops = stops
        s.zoomMin = zMin; s.zoomMax = zMax; s.zoom = z
        s.hasFlash = dev.hasTorch
        s.torch = false
        s.focusLocked = false; s.manualFocus = nil; s.aeLock = false; s.awbLock = false
        s.evStep = 0.5
        s.evMin = max(-6, Int((dev.minExposureTargetBias / 0.5).rounded(.up)))
        s.evMax = min(6, Int((dev.maxExposureTargetBias / 0.5).rounded(.down)))
        s.ev = 0
        s.fov = Double(dev.activeFormat.videoFieldOfView)
        s.error = nil
        lock.unlock()
        publishUI()
    }

    /// Arayüzden: ön ↔ arka.
    func switchCamera() {
        sessionQueue.async {
            self.lock.lock(); let f = !self.s.front && self.s.hasFront; self.lock.unlock()
            self.prefs.set(f ? "front" : "back", forKey: "position")
            self.setupInput(front: f)
        }
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
        lock.lock(); let front = s.front; lock.unlock()
        // Ön kamerada yatay duruşlar ters döner (algılayıcı arka kameraya göre 180° çevrik).
        let angle = front && (a == 0 || a == 180) ? 180 - a : a
        guard let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) else { return }
        c.videoRotationAngle = angle
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
            let front = s.front
            lock.unlock()
            prefs.set(zz, forKey: front ? "zoomFront" : "zoom")
            withDevice { $0.videoZoomFactor = CGFloat(zz) * wide }
        case "camera":
            // İzleme sayfası: "front" / "back" (Android'de kamera kimliği).
            lock.lock(); let hasFront = s.hasFront; let cur = s.front; lock.unlock()
            let f = value == "front" && hasFront
            if f != cur {
                prefs.set(f ? "front" : "back", forKey: "position")
                setupInput(front: f)
            }
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
        case "preset":
            // Hazır kalite: 1080 / 720 / 480 / 360 / 240 / 144 → boyut + JPEG kalitesi + kare hızı
            guard let h = Int(value) else { break }
            prefs.set(h, forKey: "preset")
            let (q, f) = Self.presetParams(h)
            apply("quality", String(q))
            apply("fps", String(f))
            let size = h >= 1080 ? "1920x1080" : h >= 720 ? "1280x720" : h >= 480 ? "640x480" : h >= 288 ? "640x480" : "352x288"
            apply("size", size)
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

    static let qualitySteps = [1080, 720, 480, 360, 240, 144]

    static func presetParams(_ h: Int) -> (Int, Int) {
        switch h {
        case 1080...: return (85, 30)
        case 720...: return (80, 30)
        case 480...: return (70, 25)
        case 360...: return (60, 20)
        case 240...: return (50, 15)
        default: return (40, 10)
        }
    }

    /// Şu anki kalite (kullanıcı seçmediyse çözünürlükten tahmin).
    func currentQuality() -> Int {
        if let p = prefs.object(forKey: "preset") as? Int { return p }
        lock.lock(); let m = min(s.width, s.height); lock.unlock()
        let mm = m > 0 ? m : 720
        return Self.qualitySteps.min { abs($0 - mm) < abs($1 - mm) } ?? 720
    }

    // MARK: - Durum

    private func publishUI() {
        lock.lock()
        let u = UIState(width: s.width, height: s.height, fps: s.fps, zoom: s.zoom, lensStops: s.lensStops,
                        zoomMin: s.zoomMin, zoomMax: s.zoomMax,
                        hasFlash: s.hasFlash, torch: s.torch, phonePreview: s.phonePreview,
                        isFront: s.front, canSwitch: s.hasFront, error: s.error)
        lock.unlock()
        DispatchQueue.main.async { if self.ui != u { self.ui = u } }
    }

    /// Android'deki /api/state ile aynı anahtarlar (izleme sayfası ve Mac menüsü bunları okur).
    func stateJSON(clients: Int) -> Data {
        lock.lock()
        let x = s
        lock.unlock()
        let dict: [String: Any] = [
            "cameras": [["id": "back", "label": "Arka kamera", "facing": "back"]]
                + (x.hasFront ? [["id": "front", "label": "Ön kamera", "facing": "front"]] : []),
            "cameraId": x.front ? "front" : "back",
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
            "preset": currentQuality(),
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
