// Dikiz Mikrofon — telefonun mikrofonunu Mac'te sanal mikrofon olarak kullanma.
//
// Akış: telefon  GET /<kod>/audio  (ham PCM, 16 bit, 48 kHz, mono)
//         → köprü 127.0.0.1:47800 → MicPump (titreşim tamponu)
//         → "Dikiz Mikrofon" aygıtının çıkışı → aygıtın girişi = toplantı uygulamasının mikrofonu.
//
// Sürücü (DikizMikrofon.driver) uygulamanın içinde taşınır; /Library/Audio/Plug-Ins/HAL'a
// yalnızca kullanıcı onay verip yönetici parolasını girince kopyalanır.

import AVFoundation
import Cocoa
import CoreAudio
import os

let MIC_DEVICE_UID = "DikizMikrofon_UID"

// ---- sürücü kurulumu ----
enum MicDriver {
    enum Status { case missing, outdated, ok }

    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/DikizMikrofon.driver")
    static var bundledURL: URL? { Bundle.main.url(forResource: "DikizMikrofon", withExtension: "driver") }

    private static func version(_ url: URL) -> Int {
        guard let b = Bundle(url: url), let v = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return 0 }
        return Int(v) ?? 0
    }

    static var status: Status {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .missing }
        guard let b = bundledURL else { return .ok }
        return version(installedURL) < version(b) ? .outdated : .ok
    }

    /// Yönetici parolası ister, sürücüyü kopyalar ve Core Audio'yu yeniden başlatır.
    /// Dönüş: nil = başarılı, aksi halde hata metni.
    static func install() -> String? {
        guard let src = bundledURL else { return "Uygulamanın içinde sürücü bulunamadı." }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dst = installedURL.path
        let sh = "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(q(dst)) && cp -R \(q(src.path)) \(q(dst)) && " +
                 "chown -R root:wheel \(q(dst)) && killall coreaudiod"
        let script = "do shell script \"\(sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return "" }   // kullanıcı vazgeçti
            return err[NSAppleScript.errorMessage] as? String ?? "Kurulum başarısız."
        }
        return nil
    }

    /// Sistemdeki "Dikiz Mikrofon" aygıtının kimliği (yoksa nil).
    static func deviceID() -> AudioDeviceID? {
        var uid = MIC_DEVICE_UID as CFString
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let r = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return (r == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }
}

// ---- titreşim tamponu (ağdan gelen örnekleri ses iş parçacığına aktarır) ----
final class JitterBuffer {
    private var buf: [Float]
    private var read = 0, count = 0
    private var lock = os_unfair_lock()
    private var priming = true
    let target: Int     // çalmaya başlamadan önce biriktirilecek örnek (~80 ms)
    let maxFill: Int    // bunu aşarsa en eskiler atılır (gecikme birikmesin)

    init(capacity: Int = 48_000, target: Int = 3_840, maxFill: Int = 9_600) {
        buf = [Float](repeating: 0, count: capacity)
        self.target = target
        self.maxFill = maxFill
    }

    func push(_ samples: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let cap = buf.count
        for s in samples {
            buf[(read + count) % cap] = s
            if count < cap { count += 1 } else { read = (read + 1) % cap }
        }
        if count > maxFill {   // geride kaldık: hedef gecikmeye in
            let drop = count - target
            read = (read + drop) % cap; count -= drop
        }
    }

    func pull(into out: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if priming && count >= target { priming = false }
        if priming {
            out.update(repeating: 0, count: frames); return
        }
        let n = min(frames, count)
        let cap = buf.count
        for i in 0..<n { out[i] = buf[(read + i) % cap] }
        read = (read + n) % cap; count -= n
        if n < frames {   // tampon boşaldı: sessizlik ver, yeniden biriktir
            (out + n).update(repeating: 0, count: frames - n)
            priming = true
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock); read = 0; count = 0; priming = true; os_unfair_lock_unlock(&lock)
    }
}

// ---- telefondan sesi çekip Dikiz Mikrofon'a çalan pompa ----
final class MicPump: NSObject, URLSessionDataDelegate {
    private(set) var url: URL?
    private(set) var receiving = false
    var onState: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var engine: AVAudioEngine?
    private let jitter = JitterBuffer()
    private var leftover: UInt8?          // tek sayıda bayt gelirse kalan yarım örnek
    private var retry: DispatchWorkItem?
    private var lastData = Date.distantPast

    var isRunning: Bool { url != nil }

    func start(url u: URL) {
        if url == u { return }
        stop()
        url = u
        startEngine()
        connect()
    }

    func stop() {
        url = nil
        retry?.cancel(); retry = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        engine?.stop(); engine = nil
        jitter.reset()
        leftover = nil
        setReceiving(false)
    }

    /// Core Audio yeniden başladığında (sürücü kurulumu) çıkış aygıtını yeniden bağla.
    func restartEngine() {
        guard url != nil else { return }
        engine?.stop(); engine = nil
        startEngine()
    }

    private func setReceiving(_ v: Bool) {
        guard v != receiving else { return }
        receiving = v
        DispatchQueue.main.async { self.onState?() }
    }

    private func startEngine() {
        guard let dev = MicDriver.deviceID() else { NSLog("Dikiz: Dikiz Mikrofon aygıtı yok"); return }
        let e = AVAudioEngine()
        guard let au = e.outputNode.audioUnit else { return }
        var d = dev
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { NSLog("Dikiz: çıkış aygıtı ayarlanamadı %d", st); return }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let jb = jitter
        let src = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for b in list {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                jb.pull(into: p, frames: Int(frames))
            }
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        do {
            try e.start()
            engine = e
        } catch {
            NSLog("Dikiz: ses motoru başlamadı: %@", "\(error)")
        }
    }

    private func connect() {
        guard let u = url else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10        // 10 sn veri gelmezse kopmuş say
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.dataTask(with: u)
        task = t
        t.resume()
    }

    private func scheduleRetry() {
        guard url != nil else { return }
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.url != nil else { return }
            self.session?.invalidateAndCancel()
            self.connect()
        }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session else { return }
        var bytes = [UInt8](data)
        if let l = leftover { bytes.insert(l, at: 0); leftover = nil }
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        let n = bytes.count / 2
        guard n > 0 else { return }
        var floats = [Float](repeating: 0, count: n)
        bytes.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                floats[i] = Float(v) / 32768
            }
        }
        floats.withUnsafeBufferPointer { jitter.push($0) }
        lastData = Date()
        setReceiving(true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        setReceiving(false)
        jitter.reset()
        DispatchQueue.main.async { self.scheduleRetry() }
    }
}
