import AVFoundation

/// Ses oturumu: mikrofon (AudioHub) ve hoparlör (SpeakerSink) aynı anda kullanabilir;
/// ikisi de bitince kapatılır.
enum AudioSessionUse {
    private static let lock = NSLock()
    private static var users = 0

    static func acquire() {
        lock.lock(); defer { lock.unlock() }
        users += 1
        guard users == 1 else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try s.setPreferredSampleRate(48000)
            try s.setActive(true)
        } catch {
            NSLog("Dikiz ses oturumu: %@", "\(error)")
        }
    }

    static func release() {
        lock.lock(); defer { lock.unlock() }
        users = max(0, users - 1)
        guard users == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Mac'in sesi → iPhone hoparlörü (POST /<kod>/speaker).
/// Gövde: ham PCM, 16 bit işaretli little-endian, stereo, 48 kHz. Tek gönderen; yenisi eskisinin yerini alır.
final class SpeakerSink {
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 48000 * 2)   // 1 sn stereo
    private var readPos = 0, writePos = 0, count = 0
    private var started = false
    private var engine: AVAudioEngine?
    private var generation = 0
    private var carry = Data()
    var onPlayingChanged: ((Bool) -> Void)?

    private static let prebuffer = 48000 * 2 * 120 / 1000   // 120 ms (örnek sayısı, stereo)
    private static let maxLag = 48000 * 2 * 300 / 1000
    private static let keep = 48000 * 2 * 100 / 1000

    /// Yeni gönderen bağlandı: kimlik döner; veri `feed` ile gelir, bitince `end`.
    func begin() -> Int {
        lock.lock()
        generation += 1
        let g = generation
        readPos = 0; writePos = 0; count = 0; started = false
        carry.removeAll()
        let needEngine = engine == nil
        lock.unlock()
        if needEngine { startEngine() }
        DispatchQueue.main.async { self.onPlayingChanged?(true) }
        return g
    }

    func feed(_ g: Int, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard g == generation else { return }
        var bytes = carry
        bytes.append(data)
        let usable = bytes.count - bytes.count % 2
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<(usable / 2) {
                ring[writePos] = Float(Int16(littleEndian: p[i])) / 32768
                writePos = (writePos + 1) % ring.count
                if count < ring.count { count += 1 } else { readPos = (readPos + 1) % ring.count }
            }
        }
        carry = usable < bytes.count ? bytes.suffix(from: bytes.startIndex + usable) : Data()
        // Gecikme birikmesin: 300 ms'yi aşarsa 100 ms kalacak şekilde eskiyi at
        if count > Self.maxLag {
            var drop = count - Self.keep
            drop -= drop % 2
            readPos = (readPos + drop) % ring.count
            count -= drop
        }
    }

    func end(_ g: Int) {
        lock.lock()
        guard g == generation else { lock.unlock(); return }
        generation += 1
        let e = engine
        engine = nil
        lock.unlock()
        e?.stop()
        AudioSessionUse.release()
        DispatchQueue.main.async { self.onPlayingChanged?(false) }
    }

    private func startEngine() {
        AudioSessionUse.acquire()
        let e = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return }
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl -> OSStatus in
            guard let self else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.lock.lock()
            if !self.started && self.count >= Self.prebuffer { self.started = true }
            for i in 0..<Int(frames) {
                if self.started && self.count >= 2 {
                    l[i] = self.ring[self.readPos]
                    r[i] = self.ring[(self.readPos + 1) % self.ring.count]
                    self.readPos = (self.readPos + 2) % self.ring.count
                    self.count -= 2
                } else {
                    l[i] = 0; r[i] = 0
                    if self.started { self.started = false }   // boşaldı: yeniden ön tampon bekle
                }
            }
            self.lock.unlock()
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        do {
            try e.start()
            lock.lock(); engine = e; lock.unlock()
        } catch {
            NSLog("Dikiz hoparlör: %@", "\(error)")
            AudioSessionUse.release()
        }
    }
}
