// Dikiz Kamera — telefon görüntüsünü toplantı uygulamalarına sanal kamera olarak verir.
// Görüntü telefonun duruşuna göre (X-Rotation) her zaman dik çevrilir; yatayda doldurur,
// dikte kenarları bulanık arka planla tamamlar. Telefon yoksa bekleme ekranı gösterir.

import Foundation
import CoreMediaIO
import CoreVideo
import CoreGraphics
import CoreText
import IOKit.audio
import os.log

private let kWidth: Int32 = 1920
private let kHeight: Int32 = 1080
private let kFPS: Int32 = 30
private let log = Logger(subsystem: "app.dikiz.mac.camera", category: "camera")

// MARK: - Stream

final class DikizStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let format: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.format = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kFPS) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? DikizDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? DikizDeviceSource)?.stopStreaming()
    }
}

// MARK: - Device

final class DikizDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: DikizStreamSource!
    private var streamingCounter = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "dikiz.timer", qos: .userInteractive)
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let bufferAux: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 6]
    private let feed = MJPEGFeed()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Mac menüsündeki yön ayarları (127.0.0.1:47801/vcam), saniyede bir okunur.
    private var cfgMirror = false
    private var cfgFlip = false
    private var cfgRot = 0
    private var cfgTimer: DispatchSourceTimer?

    private func pollConfig() {
        guard let u = URL(string: "http://127.0.0.1:47801/vcam") else { return }
        var req = URLRequest(url: u); req.timeoutInterval = 0.8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data, let s = String(data: data, encoding: .utf8) else { return }
            var m = false, f = false, r = 0
            for kv in s.split(separator: ";") {
                let p = kv.split(separator: "=")
                guard p.count == 2 else { continue }
                switch p[0] {
                case "mirror": m = p[1] == "1"
                case "flip": f = p[1] == "1"
                case "rot": r = Int(p[1]) ?? 0
                default: break
                }
            }
            self.timerQueue.async { self.cfgMirror = m; self.cfgFlip = f; self.cfgRot = r }
        }.resume()
    }

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: "5B3E8C2A-7D41-4F9A-9E21-D1C2B3A4E5F6")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: kWidth, height: kHeight, extensions: nil,
                                       formatDescriptionOut: &videoDescription)
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &bufferPool)

        let fmt = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                            maxFrameDuration: CMTime(value: 1, timescale: kFPS),
                                            minFrameDuration: CMTime(value: 1, timescale: kFPS),
                                            validFrameDurations: nil)
        let streamID = UUID(uuidString: "9A2C4E6B-1F3D-4B5A-8C7E-0D1F2A3B4C5D")!
        streamSource = DikizStreamSource(localizedName: "Dikiz Kamera", streamID: streamID, streamFormat: fmt, device: device)
        do { try device.addStream(streamSource.stream) } catch { log.error("addStream: \(error.localizedDescription)") }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "Dikiz Kamera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        timerQueue.async {
            self.streamingCounter += 1
            guard self.streamingCounter == 1 else { return }
            self.feed.start()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.timerQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kFPS), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.emitFrame() }
            t.resume()
            self.timer = t
            let c = DispatchSource.makeTimerSource(queue: self.timerQueue)
            c.schedule(deadline: .now(), repeating: 1.0)
            c.setEventHandler { [weak self] in self?.pollConfig() }
            c.resume()
            self.cfgTimer = c
        }
    }

    func stopStreaming() {
        timerQueue.async {
            self.streamingCounter = max(0, self.streamingCounter - 1)
            guard self.streamingCounter == 0 else { return }
            self.timer?.cancel()
            self.timer = nil
            self.cfgTimer?.cancel()
            self.cfgTimer = nil
            self.feed.stop()
        }
    }

    // MARK: kare üretimi

    private func emitFrame() {
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, bufferPool, bufferAux, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(kWidth), height: Int(kHeight),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            if let f = feed.latest, Date().timeIntervalSince(f.at) < 3 {
                draw(f, in: ctx)
            } else {
                drawWaiting(in: ctx)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: kFPS),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil,
                                                 formatDescription: videoDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sb) == noErr, let sb else { return }
        streamSource.stream.send(sb, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    /// Kareyi telefonun duruşuna göre dik çevirip çerçeveye yerleştirir.
    private func draw(_ f: MJPEGFeed.Frame, in ctx: CGContext) {
        let W = CGFloat(kWidth), H = CGFloat(kHeight)
        let iw = CGFloat(f.image.width), ih = CGFloat(f.image.height)
        let rot = (((f.rotation + cfgRot) % 360) + 360) % 360
        let sideways = rot == 90 || rot == 270
        let rw = sideways ? ih : iw, rh = sideways ? iw : ih
        let fill = max(W / rw, H / rh)
        let fit = min(W / rw, H / rh)
        // En-boy oranı çerçeveye yakınsa doldur; telefon dik duruyorsa sığdır + bulanık arka plan.
        let aspectClose = abs((rw / rh) - (W / H)) < 0.25

        ctx.interpolationQuality = .high
        if !aspectClose {
            // arka plan: aynı kareyi doldurarak, karartılmış ve büyütülmüş
            ctx.saveGState()
            place(f.image, rot: rot, scale: fill * 1.15, in: ctx)
            ctx.restoreGState()
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        ctx.saveGState()
        place(f.image, rot: rot, scale: aspectClose ? fill : fit, in: ctx)
        ctx.restoreGState()
    }

    private func place(_ img: CGImage, rot: Int, scale: CGFloat, in ctx: CGContext) {
        let W = CGFloat(kWidth), H = CGFloat(kHeight)
        let iw = CGFloat(img.width) * scale, ih = CGFloat(img.height) * scale
        ctx.translateBy(x: W / 2, y: H / 2)
        // Menüdeki ayna / yukarı-aşağı çevirme ekran düzleminde (döndürmeden sonra) uygulanır.
        ctx.scaleBy(x: cfgMirror ? -1 : 1, y: cfgFlip ? -1 : 1)
        // CoreGraphics'te pozitif açı saat yönünün tersidir; kareyi saat yönünde "rot" kadar döndür.
        ctx.rotate(by: -CGFloat(rot) * .pi / 180)
        ctx.draw(img, in: CGRect(x: -iw / 2, y: -ih / 2, width: iw, height: ih))
    }

    private func drawWaiting(in ctx: CGContext) {
        let W = CGFloat(kWidth), H = CGFloat(kHeight)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // dikiz aynası + göz
        let mirror = CGRect(x: W / 2 - 150, y: H / 2 - 10, width: 300, height: 170)
        ctx.setFillColor(CGColor(red: 0.96, green: 0.72, blue: 0.25, alpha: 1))
        ctx.addPath(CGPath(roundedRect: mirror, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1))
        ctx.addPath(CGPath(roundedRect: mirror.insetBy(dx: 18, dy: 18), cornerWidth: 30, cornerHeight: 30, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W / 2 - 60, y: H / 2 + 45, width: 120, height: 60))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W / 2 - 24, y: H / 2 + 51, width: 48, height: 48))

        text("Dikiz Kamera", size: 54, bold: true, y: H / 2 - 110, ctx: ctx, alpha: 1)
        text("Telefonda Dikiz'i aç · Mac ile aynı Wi‑Fi", size: 34, bold: false, y: H / 2 - 170, ctx: ctx, alpha: 0.6)
    }

    private func text(_ s: String, size: CGFloat, bold: Bool, y: CGFloat, ctx: CGContext, alpha: CGFloat) {
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (CGFloat(kWidth) - CGFloat(w)) / 2, y: y)
        CTLineDraw(line, ctx)
    }
}

// MARK: - Provider

final class DikizProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DikizDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DikizDeviceSource(localizedName: "Dikiz Kamera")
        do { try provider.addDevice(deviceSource.device) } catch { log.error("addDevice: \(error.localizedDescription)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Dikiz" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
