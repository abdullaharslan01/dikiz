import AVFoundation

/// Telefon mikrofonu → /<kod>/audio dinleyicileri (Android AudioHub karşılığı).
/// Biçim: ham PCM, 16 bit işaretli little-endian, mono, 48 kHz; ~20 ms'lik parçalar.
/// Mikrofon yalnızca en az bir dinleyici bağlıyken açıktır.
final class AudioHub {
    static let contentType = "audio/pcm; format=s16le; rate=48000; channels=1"

    private let q = DispatchQueue(label: "dikiz.audio")
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private var clients: [UUID: (Data) -> Void] = [:]
    private var pending = Data()
    var onListenersChanged: ((Int) -> Void)?

    static func permission(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
    }

    static var granted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    /// Yeni dinleyici; parça geldikçe `sink` çağrılır. İzin yoksa nil.
    func join(_ sink: @escaping (Data) -> Void) -> UUID? {
        guard Self.granted else { return nil }
        let id = UUID()
        q.sync {
            clients[id] = sink
            if engine == nil { startEngine() }
        }
        notify()
        return id
    }

    func leave(_ id: UUID) {
        q.async {
            self.clients[id] = nil
            if self.clients.isEmpty { self.stopEngine() }
            self.notify()
        }
    }

    private func notify() {
        let n = clients.count
        DispatchQueue.main.async { self.onListenersChanged?(n) }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            NSLog("Dikiz ses oturumu: %@", "\(error)")
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.convertAndSend(buf)
        }
        do {
            try e.start()
            engine = e
        } catch {
            input.removeTap(onBus: 0)
            NSLog("Dikiz mikrofon: %@", "\(error)")
        }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        pending.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convertAndSend(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: p, count: Int(out.frameLength) * 2)
        q.async {
            self.pending.append(data)
            let chunk = 1920   // 20 ms
            while self.pending.count >= chunk {
                let part = self.pending.prefix(chunk)
                self.pending.removeFirst(chunk)
                let d = Data(part)
                for sink in self.clients.values { sink(d) }
            }
        }
    }
}
