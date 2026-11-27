import Foundation
import Network

/// Aynı Wi‑Fi'deki Mac'e hizmet veren küçük HTTP sunucusu (Android HttpServer karşılığı).
///
///  /{kod}/             -> izleme sayfası (index.html, Android ile ortak)
///  /{kod}/stream       -> MJPEG canlı görüntü
///  /{kod}/snapshot.jpg -> tek kare
///  /{kod}/api/state    -> JSON durum
///  /{kod}/api/set?k=v  -> ayar değiştir
///
/// Kod yalnızca telefon ekranında görünür; Bonjour ilanında yalnızca kimlik, model ve ad var.
/// Yanlış kod denemeleri adres başına sınırlanır (60 sn'de 20 yanlış → 60 sn kilit).
final class HttpServer {
    private let q = DispatchQueue(label: "dikiz.http")
    private let hub: FrameHub
    private let camera: CameraController
    private let audio: AudioHub
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var code: String
    private(set) var port: UInt16 = 0

    init(hub: FrameHub, camera: CameraController, audio: AudioHub, code: String) {
        self.hub = hub
        self.camera = camera
        self.audio = audio
        self.code = code
    }

    /// 8080…8099 arasında ilk boş kapıyı dinler; hazır olunca kapıyı bildirir.
    func start(_ ready: @escaping (UInt16) -> Void) {
        q.async { self.tryPort(8080, ready) }
    }

    func stop() {
        q.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    /// Kodu değiştir ve açık bağlantıları kes: eski kodla bağlı olanlar yeni kodu girmek zorunda.
    func changeCode(_ c: String) {
        q.async {
            self.code = c
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func tryPort(_ p: UInt16, _ ready: @escaping (UInt16) -> Void) {
        guard p <= 8099 else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: p)!) else {
            tryPort(p + 1, ready); return
        }
        let txt = NWTXTRecord([
            "id": Pairing.deviceId(),
            "model": Pairing.modelIdentifier(),
            "name": String(Pairing.deviceName().prefix(60)),
        ])
        l.service = NWListener.Service(name: "Dikiz", type: "_dikiz._tcp", domain: nil, txtRecord: txt)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.port = p
                DispatchQueue.main.async { ready(p) }
            case .failed:
                l.cancel()
                if self.listener === l {
                    self.listener = nil
                    self.tryPort(p + 1, ready)
                }
            default: break
            }
        }
        listener = l
        l.start(queue: q)
    }

    // MARK: - Bağlantı

    private func accept(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        connections[key] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.connections.removeValue(forKey: key)
            default: break
            }
        }
        c.start(queue: q)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                self.route(c, head: head)
            } else if done || err != nil || buf.count > 16 * 1024 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private func remoteIP(_ c: NWConnection) -> String {
        if case let .hostPort(host, _) = c.endpoint { return "\(host)" }
        return "?"
    }

    private func route(_ c: NWConnection, head: String) {
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let comps = URLComponents(string: "http://x" + parts[1])
        let segs = (comps?.path ?? "/").split(separator: "/").map(String.init)
        let ip = remoteIP(c)

        if segs.first == "favicon.ico" { return send(c, 404, "text/plain", Data()) }
        if isLocked(ip) {
            return send(c, 429, "text/html; charset=utf-8", page("Çok fazla yanlış deneme", "Bir dakika sonra tekrar dene."))
        }
        guard let first = segs.first, first == code else {
            if !segs.isEmpty { recordFailure(ip) }
            return send(c, 404, "text/html; charset=utf-8",
                        page("Eşleşme kodu eksik ya da değişmiş",
                             "Telefondaki Dikiz ekranında yazan adresin tamamını aç (sonundaki kod dahil)."))
        }

        switch segs.count > 1 ? segs[1] : "" {
        case "", "index.html":
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
                  let html = try? String(contentsOf: url, encoding: .utf8) else {
                return send(c, 500, "text/plain", Data("sayfa yok".utf8))
            }
            send(c, 200, "text/html; charset=utf-8", Data(html.replacingOccurrences(of: "__CODE__", with: code).utf8))
        case "stream":
            stream(c)
        case "audio":
            audioStream(c)
        case "snapshot.jpg":
            hub.nextFrame(timeout: 2.5, queue: q) { [weak self] f in
                guard let self else { return }
                if let f { self.send(c, 200, "image/jpeg", f.jpeg) }
                else { self.send(c, 503, "text/plain", Data("Kare yok".utf8)) }
            }
        case "api":
            switch segs.count > 2 ? segs[2] : "" {
            case "state":
                send(c, 200, "application/json", camera.stateJSON(clients: hub.clientCount))
            case "set":
                for item in comps?.queryItems ?? [] {
                    if let v = item.value { camera.set(item.name, v) }
                }
                send(c, 200, "application/json", Data("{\"ok\":true}".utf8))
            default:
                send(c, 404, "text/plain", Data("yok".utf8))
            }
        default:
            send(c, 404, "text/plain", Data("yok".utf8))
        }
    }

    private func page(_ title: String, _ text: String) -> Data {
        Data(("<meta name=viewport content='width=device-width'><body style='font:18px system-ui;padding:24px'>" +
              "<h2>\(title)</h2><p>\(text)</p>").utf8)
    }

    private func send(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 403: reason = "Forbidden"
        case 429: reason = "Too Many Requests"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var out = Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
                        "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: - MJPEG yayını

    private func stream(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
            "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
            "Pragma: no-cache\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"
        var busy = false
        var closed = false
        var subId: UUID?

        let close: () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            if let id = subId { self?.hub.unsubscribe(id, stream: true) }
            c.cancel()
        }
        c.send(content: Data(head.utf8), completion: .contentProcessed { err in
            if err != nil { self.q.async(execute: close) }
        })
        // İstemci kapatınca haber al.
        func watchEOF() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
                if done || err != nil { self?.q.async(execute: close) } else { watchEOF() }
            }
        }
        watchEOF()

        subId = hub.subscribe(stream: true) { [weak self] f in
            guard let self else { return }
            self.q.async {
                // Yavaş istemci kareleri biriktirmesin: önceki gönderim bitmeden yenisini atla.
                guard !closed, !busy else { return }
                busy = true
                var part = Data(("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(f.jpeg.count)\r\n" +
                                 "X-Rotation: 0\r\n\r\n").utf8)
                part.append(f.jpeg)
                part.append(Data("\r\n".utf8))
                c.send(content: part, completion: .contentProcessed { err in
                    self.q.async {
                        busy = false
                        if err != nil { close() }
                    }
                })
            }
        }
        let prev = c.stateUpdateHandler
        c.stateUpdateHandler = { [weak self] st in
            prev?(st)
            switch st {
            case .failed, .cancelled: self?.q.async(execute: close)
            default: break
            }
        }
    }

    // MARK: - Mikrofon yayını (ham PCM s16le, 48 kHz, mono)

    private func audioStream(_ c: NWConnection) {
        var closed = false
        var inflight = 0
        var subId: UUID?
        let close: () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            if let id = subId { self?.audio.leave(id) }
            c.cancel()
        }
        subId = audio.join { [weak self] chunk in
            guard let self else { return }
            self.q.async {
                // Yavaş istemcide sesi biriktirme: 10 parçadan (~200 ms) fazlası beklerse at.
                guard !closed, inflight < 10 else { return }
                inflight += 1
                c.send(content: chunk, completion: .contentProcessed { err in
                    self.q.async {
                        inflight -= 1
                        if err != nil { close() }
                    }
                })
            }
        }
        guard subId != nil else {
            return send(c, 403, "text/plain; charset=utf-8", Data("Mikrofon izni yok".utf8))
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(AudioHub.contentType)\r\n" +
            "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { err in
            if err != nil { self.q.async(execute: close) }
        })
        func watchEOF() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
                if done || err != nil { self?.q.async(execute: close) } else { watchEOF() }
            }
        }
        watchEOF()
        let prev = c.stateUpdateHandler
        c.stateUpdateHandler = { [weak self] st in
            prev?(st)
            switch st {
            case .failed, .cancelled: self?.q.async(execute: close)
            default: break
            }
        }
    }

    // MARK: - Kod deneme sınırı

    private struct Tries { var count: Int; var since: Date; var lockedUntil: Date }
    private var tries: [String: Tries] = [:]

    private func isLocked(_ ip: String) -> Bool {
        (tries[ip]?.lockedUntil ?? .distantPast) > Date()
    }

    private func recordFailure(_ ip: String) {
        let now = Date()
        var t = tries[ip] ?? Tries(count: 0, since: now, lockedUntil: .distantPast)
        if now.timeIntervalSince(t.since) > 60 { t.count = 0; t.since = now }
        t.count += 1
        if t.count >= 20 { t.lockedUntil = now.addingTimeInterval(60); t.count = 0; t.since = now }
        tries[ip] = t
    }
}
