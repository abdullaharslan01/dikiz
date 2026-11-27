// Dikiz Mikrofon — telefonun mikrofonunu Mac'te sanal mikrofon olarak kullanma.
//
// Akış: telefon  GET /<kod>/audio  (ham PCM, 16 bit, 48 kHz, mono)
//         → köprü 127.0.0.1:47800 → MicPump (titreşim tamponu)
//         → "Dikiz Mikrofon" aygıtının çıkışı → aygıtın girişi = toplantı uygulamasının mikrofonu.
//
// Dikiz Hoparlör — Mac'in sesini telefonda çalma (ters yön).
//
// Akış: Mac'in varsayılan çıkışı "Dikiz Hoparlör" → aygıtın girişi → SpeakerPump
//         → POST /<kod>/speaker (ham PCM, 16 bit, 48 kHz, stereo) → köprü → telefon hoparlörü.
//
// Sürücü (DikizMikrofon.driver) uygulamanın içinde taşınır; /Library/Audio/Plug-Ins/HAL'a
// yalnızca kullanıcı onay verip yönetici parolasını girince kopyalanır.

import AVFoundation
import Cocoa
import CoreAudio
import Network
import os

let MIC_DEVICE_UID = "DikizMikrofon_UID"
let SPK_DEVICE_UID = "DikizHoparlor_UID"

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
    static func deviceID() -> AudioDeviceID? { deviceID(uid: MIC_DEVICE_UID) }

    /// Kurulu sürücüde Dikiz Hoparlör de var mı (eski sürücüde yalnızca Mikrofon vardı).
    static var hasSpeaker: Bool { deviceID(uid: SPK_DEVICE_UID) != nil }

    /// UID'den Core Audio aygıt kimliği (yoksa nil).
    static func deviceID(uid u: String) -> AudioDeviceID? {
        var uid = u as CFString
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


// ---- varsayılan çıkış aygıtı (Mac sesi nereye gidiyor) ----
enum DefaultOutput {
    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func get(system: Bool = false) -> AudioDeviceID? {
        var addr = address(system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (r == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    @discardableResult
    static func set(_ dev: AudioDeviceID, system: Bool = false) -> Bool {
        var addr = address(system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var d = dev
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
    }

    /// Aygıt kimliğinden UID (kimlikler Core Audio yeniden başlayınca değişir; UID değişmez).
    static func uid(of dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }
}

// ---- Mac sesini telefona gönderen pompa ----
final class SpeakerPump {
    private(set) var code: String?
    private(set) var sending = false
    var onState: (() -> Void)?

    private let q = DispatchQueue(label: "dikiz.speaker")
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    private let sender = SpeakerSender()
    private let defaults = UserDefaults.standard

    var isRunning: Bool { code != nil }

    init() {
        sender.onState = { [weak self] ok in
            guard let self, ok != self.sending else { return }
            self.sending = ok
            DispatchQueue.main.async { self.onState?() }
        }
    }

    /// Önceki oturum çökmüş ve çıkış Dikiz Hoparlör'de kalmışsa eski çıkışı geri ver.
    func recoverAfterCrash() {
        guard defaults.string(forKey: "spkPrevOutput") != nil else { return }
        restoreOutput()
    }

    func start(code c: String) {
        if code == c { return }
        let wasRunning = isRunning
        code = c
        if !wasRunning {
            guard switchOutputToSpeaker() else { code = nil; return }
            startEngine()
        }
        sender.start(path: "/\(c)/speaker")
    }

    /// Durdur ve Mac'in sesini önceki çıkışa geri ver.
    func stop() {
        guard isRunning else { return }
        code = nil
        sender.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        converter = nil
        restoreOutput()
    }

    /// Core Audio yeniden başladığında (sürücü güncellemesi) aygıtı yeniden bağla.
    func restartEngine() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        _ = switchOutputToSpeaker()
        startEngine()
    }

    // ---- varsayılan çıkışı değiştir / geri ver ----
    private func switchOutputToSpeaker() -> Bool {
        guard let spk = MicDriver.deviceID(uid: SPK_DEVICE_UID) else { NSLog("Dikiz: Dikiz Hoparlör aygıtı yok"); return false }
        // Önceki çıkışları UID olarak sakla (çökmede bile geri verilebilsin); zaten Hoparlör'deyse üzerine yazma.
        if let cur = DefaultOutput.get(), cur != spk, let u = DefaultOutput.uid(of: cur) { defaults.set(u, forKey: "spkPrevOutput") }
        if let cur = DefaultOutput.get(system: true), cur != spk, let u = DefaultOutput.uid(of: cur) { defaults.set(u, forKey: "spkPrevSystemOutput") }
        DefaultOutput.set(spk)
        DefaultOutput.set(spk, system: true)
        return true
    }

    private func restoreOutput() {
        let spk = MicDriver.deviceID(uid: SPK_DEVICE_UID)
        for (key, system) in [("spkPrevOutput", false), ("spkPrevSystemOutput", true)] {
            // Kullanıcı bu arada başka bir çıkış seçtiyse ona dokunma; yalnızca hâlâ Hoparlör'deyse geri ver.
            if let uid = defaults.string(forKey: key), let prev = MicDriver.deviceID(uid: uid),
               spk == nil || DefaultOutput.get(system: system) == spk {
                DefaultOutput.set(prev, system: system)
            }
            defaults.removeObject(forKey: key)
        }
    }

    // ---- Dikiz Hoparlör girişinden yakala → s16le stereo 48 kHz ----
    private func startEngine() {
        guard let dev = MicDriver.deviceID(uid: SPK_DEVICE_UID) else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        guard let au = input.audioUnit else { return }
        var d = dev
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { NSLog("Dikiz: Hoparlör girişi seçilemedi %d", st); return }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        converter = conv
        let snd = sender
        input.installTap(onBus: 0, bufferSize: 960, format: inFormat) { [weak self] buf, _ in
            guard let self, let data = self.convert(buf) else { return }
            snd.send(data)
        }
        do {
            try e.start()
            engine = e
        } catch {
            input.removeTap(onBus: 0)
            NSLog("Dikiz: Hoparlör yakalama başlamadı: %@", "\(error)")
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> Data? {
        guard let conv = converter else { return nil }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: p, count: Int(out.frameLength) * 4)   // 2 kanal × 2 bayt
    }
}

/// Köprü üzerinden telefona tek bir uzun POST: başlık + bitmeyen ham PCM gövdesi.
/// Bağlantı koparsa 1,5 sn sonra yeniden bağlanır; ağ yavaşsa eski parçaları atar (gecikme birikmesin).
final class SpeakerSender {
    var onState: ((Bool) -> Void)?
    var port: UInt16 = LOCAL_PORT
    private let q = DispatchQueue(label: "dikiz.speaker.net")
    private var conn: NWConnection?
    private var path: String?
    private var ready = false
    private var inflight = 0
    private var retry: DispatchWorkItem?
    private(set) var sentBytes = 0

    func start(path p: String) {
        q.async {
            if self.path == p, self.conn != nil { return }
            self.path = p
            self.reconnect(now: true)
        }
    }

    func stop() {
        q.async {
            self.path = nil
            self.retry?.cancel(); self.retry = nil
            self.conn?.cancel(); self.conn = nil
            self.setReady(false)
        }
    }

    func send(_ data: Data) {
        q.async {
            guard let c = self.conn, self.ready else { return }
            guard self.inflight < 15 else { return }   // ~150–300 ms birikti: bu parçayı at
            self.inflight += 1
            c.send(content: data, completion: .contentProcessed { [weak self] err in
                self?.q.async {
                    guard let self else { return }
                    self.inflight -= 1
                    if err == nil { self.sentBytes += data.count } else { self.reconnect(now: false) }
                }
            })
        }
    }

    private func setReady(_ v: Bool) {
        guard v != ready else { return }
        ready = v
        onState?(v)
    }

    private func reconnect(now: Bool) {
        conn?.cancel(); conn = nil
        setReady(false)
        inflight = 0
        retry?.cancel()
        guard path != nil else { return }
        if !now {
            let w = DispatchWorkItem { [weak self] in self?.reconnect(now: true) }
            retry = w
            q.asyncAfter(deadline: .now() + 1.5, execute: w)
            return
        }
        guard let p = path, let port = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                let head = "POST \(p) HTTP/1.1\r\nHost: dikiz\r\n" +
                    "Content-Type: audio/pcm; format=s16le; rate=48000; channels=2\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                self.readResponse(c)
            case .failed, .cancelled:
                if c === self.conn { self.reconnect(now: false) }
            default: break
            }
        }
        c.start(queue: q)
    }

    /// Telefonun yanıtı: 200 gelince ses gönderilmeye başlar; bağlantı kapanırsa yeniden bağlan.
    private func readResponse(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !self.ready {
                let head = String(decoding: data, as: UTF8.self)
                if head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") {
                    self.setReady(true)
                } else {
                    NSLog("Dikiz: telefon hoparlör isteğini kabul etmedi: %@", String(head.prefix(40)))
                    self.reconnect(now: false)
                    return
                }
            }
            if done || err != nil { self.reconnect(now: false); return }
            self.readResponse(c)   // telefon başka bir şey yazmaz; kapanışı yakalamak için dinle
        }
    }
}
