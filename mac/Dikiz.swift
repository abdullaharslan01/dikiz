// Dikiz (Mac) — telefondaki Dikiz uygulamasını aynı Wi‑Fi'de Bonjour ile bulur,
// 127.0.0.1:47800 üzerinden köprü kurar ve izleme sayfasını uygulama penceresinde açar.
//
// Neden köprü? Tarayıcılar mikrofon (sesli komut) ve Mac kamerasına (ön ayna) yalnızca
// "güvenli" adreslerde izin verir; http://127.0.0.1 güvenli sayılır, http://192.168.x.x sayılmaz.
// Ayrıca telefonun IP'si değişse bile adres hep aynı kalır, ayarların kaybolmaz.

import Cocoa
import Network
import ServiceManagement
import SystemExtensions

let CAMERA_EXTENSION_ID = "app.dikiz.mac.camera"

let LOCAL_PORT: UInt16 = 47800

final class Bridge {
    private let q = DispatchQueue(label: "dikiz.bridge")
    private var listener: NWListener?
    private var browser: NWBrowser?

    /// Aynı ağda bulunan Dikiz telefonları (birden fazla kişi aynı Wi‑Fi'de olabilir).
    /// Ad yalnızca eski sürüm telefonların ilanında olur; yenilerde ad kodla (/api/state) öğrenilir.
    struct Phone { let id: String; let name: String?; let endpoint: NWEndpoint }
    private(set) var phones: [Phone] = []

    // Eşleşilen telefon: kimliği ve kodu kalıcı; Mac yalnızca bu telefona bağlanır.
    private let defaults = UserDefaults.standard
    var pairedId: String? { defaults.string(forKey: "pairedId") }
    var pairedName: String? { defaults.string(forKey: "pairedName") }
    private var pairedCode: String? { defaults.string(forKey: "pairedCode") }

    private(set) var target: NWEndpoint?
    private(set) var code: String?
    private(set) var model: String?
    /// Telefonda kod değiştirilmiş: eski kod artık geçmiyor.
    private(set) var codeRejected = false
    var onChange: (() -> Void)?
    var listenError: String?
    /// Sanal kameranın yön ayarı ("mirror=1;flip=0;rot=90"); menüden değişir, eklenti okur.
    var vcamConfig: () -> String = { "mirror=0;flip=0;rot=0" }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LOCAL_PORT)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.listenError = "\(e)"; self?.notify() }
            }
            l.start(queue: q)
            listener = l
        } catch {
            listenError = "\(error)"
        }
        startCameraFeed()
        restartBrowse()
    }

    // ---- 127.0.0.1:47801 — Dikiz Kamera (sanal kamera) için kodsuz besleme ----
    // Sanal kamera eklentisi ayrı bir kullanıcıda çalıştığı için erişim kodunu bilemez;
    // buraya gelen "GET /stream" isteğini "GET /<kod>/stream" olarak telefona iletiriz.
    private var feedListener: NWListener?

    private func startCameraFeed() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LOCAL_PORT + 1)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handleFeed(c) }
        l.start(queue: q)
        feedListener = l
    }

    private func handleFeed(_ inbound: NWConnection) {
        inbound.start(queue: q)
        inbound.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            // Yön ayarını köprü kendisi yanıtlar (telefona gitmez).
            if let self, let data, let req = String(data: data, encoding: .utf8), req.hasPrefix("GET /vcam") {
                let body = self.vcamConfig()
                let msg = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                inbound.send(content: msg.data(using: .utf8), completion: .contentProcessed { _ in inbound.cancel() })
                return
            }
            guard let self, let t = self.target, let code = self.code,
                  let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else {
                let msg = "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                inbound.send(content: msg.data(using: .utf8), completion: .contentProcessed { _ in inbound.cancel() })
                return
            }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/stream"
            let outbound = NWConnection(to: t, using: .tcp)
            outbound.start(queue: self.q)
            let fwd = "GET /\(code)\(path.hasPrefix("/") ? path : "/" + path) HTTP/1.1\r\nHost: dikiz\r\nConnection: close\r\n\r\n"
            outbound.send(content: fwd.data(using: .utf8), completion: .contentProcessed { _ in })
            self.pipe(outbound, inbound)
            self.pipe(inbound, outbound)
        }
    }

    func restartBrowse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_dikiz._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.phones = results.map { r in
                var id = "", name = "", model = ""
                if case let .bonjour(txt) = r.metadata {
                    id = txt["id"] ?? ""; name = txt["name"] ?? ""; model = txt["model"] ?? ""
                }
                if case let .service(svc, _, _, _) = r.endpoint, id.isEmpty { id = "svc:" + svc }  // eski sürüm telefon
                let shown = name.isEmpty ? (model.isEmpty ? nil : model) : name
                return Phone(id: id, name: shown, endpoint: r.endpoint)
            }
            self.recompute()
        }
        b.start(queue: q)
        browser = b
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    /// Eşleşilen telefon ağdaysa ona bağlan; başka telefonlara asla bağlanma.
    private func recompute() {
        if let id = pairedId, let p = phones.first(where: { $0.id == id }), let c = pairedCode, !codeRejected {
            target = p.endpoint; code = c; model = pairedName ?? p.name ?? "Telefon"
        } else {
            target = nil; code = nil; model = nil
        }
        notify()
    }

    func pair(_ phone: Phone, code c: String, name: String?) {
        q.async {
            self.defaults.set(phone.id, forKey: "pairedId")
            self.defaults.set(name ?? phone.name ?? "Telefon", forKey: "pairedName")
            self.defaults.set(c, forKey: "pairedCode")
            self.codeRejected = false
            self.recompute()
        }
    }

    func unpair() {
        q.async {
            ["pairedId", "pairedName", "pairedCode"].forEach { self.defaults.removeObject(forKey: $0) }
            self.codeRejected = false
            self.recompute()
        }
    }

    /// Telefon kodu kabul etmedi (telefonda kod değiştirilmiş) → bağlantıyı bırak, yeniden kod iste.
    func markCodeRejected() {
        q.async {
            guard self.code != nil else { return }
            self.codeRejected = true
            self.recompute()
        }
    }

    /// Telefon adı değişmişse (kodla öğrenilen) güncelle.
    func updateName(_ name: String) {
        q.async {
            guard self.code != nil, name != self.pairedName else { return }
            self.defaults.set(name, forKey: "pairedName")
            self.recompute()
        }
    }

    /// Kodu doğrudan telefona sorar: GET /<kod>/api/state → 200 ise doğru; telefonun adını da döner.
    func verify(_ phone: Phone, code c: String, done: @escaping (Bool, String?) -> Void) {
        let conn = NWConnection(to: phone.endpoint, using: .tcp)
        var finished = false
        var acc = Data()
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            conn.cancel()
            var name: String?
            if ok, let r = acc.range(of: Data("\r\n\r\n".utf8)),
               let j = try? JSONSerialization.jsonObject(with: acc[r.upperBound...]) as? [String: Any] {
                name = j["deviceName"] as? String
            }
            done(ok, name)
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                let req = "GET /\(c)/api/state HTTP/1.1\r\nHost: dikiz\r\nConnection: close\r\n\r\n"
                conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                func read() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isDone, err in
                        if let data { acc.append(data) }
                        if isDone || err != nil || acc.count > 256 * 1024 {
                            finish(acc.starts(with: Data("HTTP/1.1 200".utf8)))
                        } else { read() }
                    }
                }
                read()
            case .failed, .cancelled:
                finish(false)
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 6) { finish(false) }
    }

    // Tarayıcıdan gelen her TCP bağlantısını telefona aktar (bayt bayt, iki yönlü).
    private func handle(_ inbound: NWConnection) {
        guard let t = target else { inbound.cancel(); return }
        let outbound = NWConnection(to: t, using: .tcp)
        inbound.start(queue: q)
        outbound.start(queue: q)
        pipe(inbound, outbound)
        pipe(outbound, inbound)
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            let finished = isComplete || error != nil
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendErr in
                    if sendErr != nil || finished {
                        from.cancel(); to.cancel()
                    } else {
                        self?.pipe(from, to)
                    }
                })
            } else if finished {
                from.cancel(); to.cancel()
            } else {
                self?.pipe(from, to)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate, NSMenuDelegate {
    let bridge = Bridge()
    let micPump = MicPump()
    let speakerPump = SpeakerPump()
    var item: NSStatusItem!
    var openedOnce = false
    var warned = false
    var cameraStatus = "Toplantı kamerası kuruluyor…"
    var cameraReady = false
    var approvalAlertShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Dikiz")
        bridge.onChange = { [weak self] in self?.refresh(); self?.pollPhone(); self?.maybeAskPairing() }
        bridge.vcamConfig = {
            let d = UserDefaults.standard
            func b(_ k: String) -> Int { d.bool(forKey: k) ? 1 : 0 }
            return "mirror=\(b("vcamMirror"));flip=\(b("vcamFlip"));rot=\(d.integer(forKey: "vcamRot"))" +
                ";blur=\(b("fxBlur"));beauty=\(b("fxBeauty"))" +
                ";filter=\(d.string(forKey: "fxFilter") ?? "none")"
        }
        micPump.onState = { [weak self] in self?.refresh() }
        speakerPump.onState = { [weak self] in self?.refresh() }
        speakerPump.recoverAfterCrash()   // önceki oturumda çıkış Dikiz Hoparlör'de kaldıysa geri ver
        bridge.start()
        installCameraExtension()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollPhone() }
        // Telefon yoksa araya girmeyiz: durum yalnızca menü çubuğundaki simgede görünür (üstü çizili göz).
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openViewer()
        return false
    }

    // ---- Menüdeki canlı önizleme (küçük ayna) ----
    private lazy var preview: PreviewView = {
        let v = PreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        v.onClick = { [weak self] in self?.openViewer() }
        return v
    }()
    private lazy var previewItem: NSMenuItem = {
        let it = NSMenuItem()
        it.view = preview
        return it
    }()
    private var menuOpen = false
    private var refreshPending = false

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if bridge.code != nil {
            preview.mirror = vcamMirror        // toplantıda görünen yönle aynı
            preview.extraRotation = vcamRot
            preview.start()
        } else {
            preview.setWaiting(bridge.phones.isEmpty ? "Telefon aranıyor…" : "Telefonu eşleştir")
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        preview.stop()
        if refreshPending { refreshPending = false; refresh() }
    }

    func refresh() {
        // Menü açıkken yeniden kurma: önizleme kaybolmasın; kapanınca güncellenir.
        if menuOpen { refreshPending = true; return }
        let menu = NSMenu()
        menu.delegate = self
        previewItem.menu?.removeItem(previewItem)
        menu.addItem(previewItem)
        let status: String
        if let e = bridge.listenError {
            status = "Hata: \(e)"
        } else if bridge.code != nil {
            status = "● \(bridge.model ?? "Telefon") bağlı"
        } else if bridge.codeRejected {
            status = "⚠︎ \(bridge.pairedName ?? "Telefon"): kod değişmiş"
        } else if let name = bridge.pairedName {
            status = "○ \(name) aranıyor…"
        } else if bridge.phones.isEmpty {
            status = "○ Telefon aranıyor…"
        } else {
            status = "○ Telefon eşleştirilmedi"
        }
        let s = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Görüntüyü aç", action: #selector(openViewerAction), keyEquivalent: "o")
        open.target = self
        open.isEnabled = bridge.code != nil
        menu.addItem(open)
        let pairTitle = bridge.codeRejected ? "Yeni kodu gir…" : (bridge.pairedId == nil ? "Telefonu eşleştir…" : "Telefonu değiştir…")
        let pairItem = NSMenuItem(title: pairTitle, action: #selector(pairAction), keyEquivalent: "p")
        pairItem.target = self
        pairItem.isEnabled = !bridge.phones.isEmpty
        menu.addItem(pairItem)
        if bridge.pairedId != nil {
            let un = NSMenuItem(title: "Eşleşmeyi kaldır", action: #selector(unpairAction), keyEquivalent: "")
            un.target = self
            menu.addItem(un)
        }
        let again = NSMenuItem(title: "Telefonu yeniden ara", action: #selector(rescan), keyEquivalent: "r")
        again.target = self
        menu.addItem(again)
        menu.addItem(.separator())

        // ---- Toplantı kamerası: hızlı yön ayarları ----
        menu.addItem(header("Toplantı kamerası"))
        let cam = NSMenuItem(title: cameraStatus, action: nil, keyEquivalent: "")
        cam.isEnabled = false
        menu.addItem(cam)
        if !cameraReady {
            let fix = NSMenuItem(title: "Kamera eklentisini onayla…", action: #selector(openExtensionSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(action("Sağ-sol çevir", symbol: "arrow.left.and.right", #selector(toggleMirror), key: "m", on: vcamMirror))
        menu.addItem(action("Yukarı-aşağı çevir", symbol: "arrow.up.and.down", #selector(toggleFlip), key: "u", on: vcamFlip))
        menu.addItem(action("90° döndür" + (vcamRot != 0 ? "  (\(vcamRot)°)" : ""), symbol: "rotate.right", #selector(rotateCam), key: "d", on: vcamRot != 0))
        if vcamMirror || vcamFlip || vcamRot != 0 {
            menu.addItem(action("Yönü sıfırla", symbol: "arrow.counterclockwise", #selector(resetCam), key: ""))
        }

        // ---- Efektler (Apple Vision + CoreImage, cihaz üzerinde) ----
        menu.addItem(.separator())
        menu.addItem(header("Efektler"))
        menu.addItem(fx("Arka planı bulanıklaştır", symbol: "person.and.background.dotted", key: "fxBlur"))
        menu.addItem(fx("Güzelleştirme", symbol: "sparkles", key: "fxBeauty"))
        let filterItem = NSMenuItem(title: "Filtre", action: nil, keyEquivalent: "")
        filterItem.image = NSImage(systemSymbolName: "camera.filters", accessibilityDescription: nil)
        let filterMenu = NSMenu()
        let current = defaults.string(forKey: "fxFilter") ?? "none"
        for (id, name) in [("none", "Yok"), ("warm", "Sıcak"), ("cool", "Soğuk"), ("vivid", "Canlı"), ("mono", "Siyah-beyaz"), ("cinema", "Sinema")] {
            let it = NSMenuItem(title: name, action: #selector(setFilter(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = id
            it.state = id == current ? .on : .off
            filterMenu.addItem(it)
        }
        filterItem.submenu = filterMenu
        if current != "none" { filterItem.title = "Filtre: " + (filterMenu.items.first { ($0.representedObject as? String) == current }?.title ?? "") }
        menu.addItem(filterItem)

        // ---- Ses: telefon mikrofonu → Dikiz Mikrofon; Mac sesi → Dikiz Hoparlör → telefon ----
        menu.addItem(.separator())
        menu.addItem(header("Ses"))
        let drv = MicDriver.status
        if drv != .ok {
            let inst = action(drv == .missing ? "Dikiz ses sürücüsünü kur…" : "Dikiz ses sürücüsünü güncelle…",
                              symbol: "mic.badge.plus", #selector(installMicDriver), key: "")
            menu.addItem(inst)
        }
        let micItem = action("Telefon mikrofonunu Dikiz Mikrofon'a aktar", symbol: "mic", #selector(toggleMic), key: "", on: micOn)
        micItem.isEnabled = drv != .missing
        menu.addItem(micItem)
        if micOn && drv != .missing {
            let st = NSMenuItem(title: micPump.receiving ? "● Ses aktarılıyor" : (bridge.code == nil ? "○ Telefon bekleniyor" : "○ Ses bağlanıyor…"),
                                action: nil, keyEquivalent: "")
            st.isEnabled = false
            menu.addItem(st)
        }
        syncMic()

        let spkItem = action("Bilgisayar sesini telefonda çal", symbol: "hifispeaker", #selector(toggleSpeaker), key: "", on: speakerOn)
        menu.addItem(spkItem)
        if speakerOn && drv == .ok {
            let st = NSMenuItem(title: speakerPump.sending ? "● Mac sesi telefona gidiyor"
                                    : (bridge.code == nil ? "○ Telefon bekleniyor" : "○ Telefona bağlanıyor…"),
                                action: nil, keyEquivalent: "")
            st.isEnabled = false
            menu.addItem(st)
        }
        syncSpeaker()

        // ---- Telefon: lens ve ışık ----
        if bridge.code != nil {
            menu.addItem(.separator())
            menu.addItem(header("Telefon"))
            for z in phoneLensStops {
                let name = z < 0.95 ? "Geniş" : (abs(z - 1) < 0.05 ? "Ana" : "Tele")
                let it = action("\(name)  \(String(format: "%g", (z * 10).rounded() / 10))×", symbol: "camera.aperture", #selector(setLens(_:)), key: "",
                                on: abs(z - phoneZoom) < 0.06)
                it.representedObject = z
                menu.addItem(it)
            }
            if phoneHasFlash {
                menu.addItem(action("Işık", symbol: "lightbulb", #selector(toggleTorch), key: "", on: phoneTorch))
            }
            // Kalite: yavaş ağda düşür (telefon boyut + JPEG kalitesi + kare hızını birlikte ayarlar)
            let q = NSMenuItem(title: phonePreset > 0 ? "Kalite: \(phonePreset)p" : "Kalite", action: nil, keyEquivalent: "")
            q.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: nil)
            let qm = NSMenu()
            for h in [1080, 720, 480, 360, 240, 144] {
                let it = NSMenuItem(title: "\(h)p", action: #selector(setPreset(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = h
                it.state = h == phonePreset ? .on : .off
                qm.addItem(it)
            }
            q.submenu = qm
            menu.addItem(q)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Mac açılınca başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Dikiz'den çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        item.button?.image = NSImage(
            systemSymbolName: bridge.code != nil ? "eye.fill" : "eye.slash",
            accessibilityDescription: "Dikiz"
        )

        // İlk bulunuşta izleme penceresini aç (Mac açılışında yalnızca kamera için başlıyorsa açma).
        if bridge.code != nil && !openedOnce {
            openedOnce = true
            if SMAppService.mainApp.status != .enabled { openViewer() }
        }
    }

    // ---- menü yardımcıları ----
    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false; return h
    }

    private func action(_ title: String, symbol: String, _ sel: Selector, key: String, on: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        it.state = on ? .on : .off
        return it
    }

    // ---- sanal kamera yönü (kalıcı) ----
    private let defaults = UserDefaults.standard
    var vcamMirror: Bool { get { defaults.bool(forKey: "vcamMirror") } set { defaults.set(newValue, forKey: "vcamMirror") } }
    var vcamFlip: Bool { get { defaults.bool(forKey: "vcamFlip") } set { defaults.set(newValue, forKey: "vcamFlip") } }
    var vcamRot: Int { get { defaults.integer(forKey: "vcamRot") } set { defaults.set(newValue, forKey: "vcamRot") } }

    @objc func toggleMirror() { vcamMirror.toggle(); refresh() }
    @objc func toggleFlip() { vcamFlip.toggle(); refresh() }
    @objc func rotateCam() { vcamRot = (vcamRot + 90) % 360; refresh() }
    @objc func resetCam() { vcamMirror = false; vcamFlip = false; vcamRot = 0; refresh() }

    // ---- efektler (kalıcı) ----
    private func fx(_ title: String, symbol: String, key: String) -> NSMenuItem {
        let it = action(title, symbol: symbol, #selector(toggleFx(_:)), key: "", on: defaults.bool(forKey: key))
        it.representedObject = key
        return it
    }
    @objc func toggleFx(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: k), forKey: k)
        refresh()
    }
    @objc func setFilter(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String ?? "none", forKey: "fxFilter")
        refresh()
    }

    // ---- ses aktarımı (kalıcı) ----
    var micOn: Bool { get { defaults.bool(forKey: "micToDevice") } set { defaults.set(newValue, forKey: "micToDevice") } }

    /// Açıksa ve telefon bağlıysa telefonun mikrofonunu çek; değilse bırak (telefonda mikrofon kapanır).
    func syncMic() {
        if micOn, MicDriver.status != .missing, let code = bridge.code,
           let u = URL(string: "http://127.0.0.1:\(LOCAL_PORT)/\(code)/audio") {
            micPump.start(url: u)
        } else if micPump.isRunning {
            micPump.stop()
        }
    }

    @objc func toggleMic() {
        micOn.toggle()
        refresh()
    }

    // ---- Mac sesi → telefon (kalıcı anahtar) ----
    var speakerOn: Bool { get { defaults.bool(forKey: "speakerToPhone") } set { defaults.set(newValue, forKey: "speakerToPhone") } }
    private var speakerAfterInstall = false

    /// Açıksa ve telefon bağlıysa Mac'in çıkışını Dikiz Hoparlör'e al ve sesi telefona gönder;
    /// kapanınca ya da telefon gidince önceki çıkışa geri dön.
    func syncSpeaker() {
        if speakerOn, MicDriver.status == .ok, MicDriver.hasSpeaker, let code = bridge.code {
            speakerPump.start(code: code)
        } else if speakerPump.isRunning {
            speakerPump.stop()
        }
    }

    @objc func toggleSpeaker() {
        if !speakerOn && (MicDriver.status != .ok || !MicDriver.hasSpeaker) {
            // Sürücü yok ya da eski (Hoparlör yok): önce kurulum
            speakerAfterInstall = true
            installMicDriver()
            return
        }
        speakerOn.toggle()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        speakerPump.stop()   // Mac'in sesini önceki çıkışa geri ver
    }

    @objc func installMicDriver() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Dikiz ses sürücüsünü kur"
        a.informativeText = "Mac'e küçük bir ses sürücüsü kurulur. İki şey sağlar:\n\n" +
            "• Dikiz Mikrofon: telefonunun mikrofonu Zoom, Meet, Teams ve FaceTime'da mikrofon olarak seçilir.\n" +
            "• Dikiz Hoparlör: Mac'in sesi telefonda çalar.\n\n" +
            "Kurulum için Mac'in yönetici parolası bir kez sorulur. Kurulum sırasında ses birkaç saniye kesilebilir."
        a.addButton(withTitle: "Kur")
        a.addButton(withTitle: "Vazgeç")
        guard a.runModal() == .alertFirstButtonReturn else { speakerAfterInstall = false; return }
        if let err = MicDriver.install() {
            speakerAfterInstall = false
            if !err.isEmpty {
                let e = NSAlert()
                e.messageText = "Dikiz Mikrofon kurulamadı"
                e.informativeText = err
                e.runModal()
            }
            return
        }
        // Core Audio yeniden başlıyor; aygıt birkaç saniye içinde görünür.
        if speakerAfterInstall { speakerAfterInstall = false; speakerOn = true } else if !micOn { micOn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.micPump.restartEngine()
            self?.speakerPump.restartEngine()
            self?.refresh()
        }
        refresh()
    }

    // ---- telefon durumu (lens / ışık) ----
    var phoneLensStops: [Double] = []
    var phoneZoom: Double = 1
    var phoneTorch = false
    var phoneHasFlash = false
    var phonePreset = 0

    func pollPhone() {
        guard let code = bridge.code,
              let u = URL(string: "http://127.0.0.1:\(LOCAL_PORT)/\(code)/api/state") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, resp, _ in
            // 404: telefonda kod değiştirilmiş → eski kodla denemeyi bırak, yeni kodu sor.
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                self?.bridge.markCodeRejected()
                return
            }
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let stops = (j["lensStops"] as? [Double]) ?? []
                let zoom = (j["zoom"] as? Double) ?? 1
                let torch = (j["torch"] as? Bool) ?? false
                let flash = (j["hasFlash"] as? Bool) ?? false
                if let dn = j["deviceName"] as? String, !dn.isEmpty { self.bridge.updateName(dn) }
                let preset = (j["preset"] as? Int) ?? 0
                if preset != self.phonePreset { self.phonePreset = preset; self.refresh() }
                if stops != self.phoneLensStops || abs(zoom - self.phoneZoom) > 0.01 || torch != self.phoneTorch || flash != self.phoneHasFlash {
                    self.phoneLensStops = stops; self.phoneZoom = zoom; self.phoneTorch = torch; self.phoneHasFlash = flash
                    self.refresh()
                }
            }
        }.resume()
    }

    private func phoneSet(_ query: String) {
        guard let code = bridge.code,
              let u = URL(string: "http://127.0.0.1:\(LOCAL_PORT)/\(code)/api/set?\(query)") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.pollPhone() }
        }.resume()
    }

    @objc func setLens(_ sender: NSMenuItem) {
        if let z = sender.representedObject as? Double { phoneSet("zoom=\(z)") }
    }
    @objc func setPreset(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? Int { phoneSet("preset=\(h)") }
    }
    @objc func toggleTorch() { phoneSet("torch=\(phoneTorch ? 0 : 1)") }

    // ---- Toplantı kamerası (CoreMediaIO Camera Extension) ----
    func installCameraExtension() {
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: CAMERA_EXTENSION_ID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        cameraStatus = "Toplantı kamerası: onay bekliyor"
        NSLog("DikizCam: needs user approval")
        cameraReady = false
        refresh()
        // Uyarıyı oturum başına yalnızca bir kez göster; onay verilince istek kendiliğinden tamamlanır.
        guard !approvalAlertShown else { return }
        approvalAlertShown = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Dikiz Kamera'ya izin ver"
        a.informativeText = "Telefonunu Meet, Zoom ve Teams'te kamera olarak kullanmak için bir kerelik onay gerekiyor.\n\nAçılacak pencerede “Kamera Uzantıları” altında Dikiz'i aç."
        a.addButton(withTitle: "Ayarları aç")
        a.addButton(withTitle: "Sonra")
        if a.runModal() == .alertFirstButtonReturn { openExtensionSettings() }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        cameraReady = result == .completed
        NSLog("DikizCam: finished result=%d", result.rawValue)
        cameraStatus = cameraReady ? "✓ Toplantı kamerası hazır (“Dikiz Kamera”)" : "Toplantı kamerası: yeniden başlatma gerekli"
        refresh()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        cameraReady = false
        cameraStatus = "Toplantı kamerası kurulamadı: \(error.localizedDescription)"
        NSLog("DikizCam: failed %@", "\(error)")
        refresh()
    }

    @objc func openExtensionSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
        refresh()
    }

    @objc func openViewerAction() { openViewer() }
    @objc func rescan() { bridge.restartBrowse() }
    @objc func pairAction() { askPairing(preferred: bridge.pairedId) }
    @objc func unpairAction() { bridge.unpair() }

    // ---- Eşleşme: telefonda görünen 6 haneli kodu bir kez gir ----
    var pairingOpen = false
    var autoAskedState = ""

    /// Kendiliğinden yalnızca bir kez sorar: hiç eşleşme yokken telefon görününce
    /// ya da eşleşilen telefonun kodu değişince. Başkasının telefonu için araya girmez.
    func maybeAskPairing() {
        guard !pairingOpen, bridge.code == nil, !bridge.phones.isEmpty else { return }
        let rejectedHere = bridge.codeRejected && bridge.phones.contains { $0.id == bridge.pairedId }
        guard bridge.pairedId == nil || rejectedHere else { return }
        let state = "\(bridge.pairedId ?? "-")/\(bridge.codeRejected)"
        guard state != autoAskedState else { return }
        autoAskedState = state
        DispatchQueue.main.async { self.askPairing(preferred: self.bridge.pairedId) }
    }

    func askPairing(preferred: String?, error: String? = nil, picked: String? = nil) {
        let phones = bridge.phones
        guard !phones.isEmpty, !pairingOpen else { if phones.isEmpty { warnNotFound() }; return }
        pairingOpen = true
        defer { pairingOpen = false }
        NSApp.activate(ignoringOtherApps: true)

        // Gizlilik: ağdaki telefonlar listelenmez. Kod girilir; Mac kodu ağdaki Dikiz
        // telefonlarına sorar ve kabul edenle eşleşir.
        let a = NSAlert()
        a.messageText = error ?? (bridge.codeRejected ? "Telefondaki kod değişmiş" : "Telefonu eşleştir")
        a.informativeText = "Telefonda Dikiz'i aç; ekranın üstünde yazan 6 haneli kodu gir.\n" +
            "Bir kez girmen yeter: Mac bundan sonra yalnızca bu telefona bağlanır."
        if error != nil { a.alertStyle = .warning }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        field.placeholderString = "Kod (ör. 482 913)"
        field.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        a.accessoryView = field
        a.addButton(withTitle: "Eşleştir")
        a.addButton(withTitle: "Vazgeç")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let code = field.stringValue.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !code.isEmpty else {
            pairingOpen = false
            return askPairing(preferred: preferred, error: "Kodu yazmadın")
        }
        // Kodu tüm telefonlara aynı anda sor; doğru kodu yalnızca bir telefon kabul eder.
        let group = DispatchGroup()
        let lock = NSLock()
        var match: (Bridge.Phone, String?)?
        for p in phones {
            group.enter()
            bridge.verify(p, code: code) { ok, name in
                if ok { lock.lock(); if match == nil { match = (p, name) }; lock.unlock() }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 7)
        pairingOpen = false
        lock.lock(); let m = match; lock.unlock()
        if let (phone, name) = m {
            bridge.pair(phone, code: code, name: name)
            openedOnce = false   // eşleşince görüntüyü aç
        } else {
            askPairing(preferred: preferred, error: "Kod tutmadı, telefondaki kodu kontrol et")
        }
    }

    func openViewer() {
        guard let code = bridge.code else {
            if bridge.phones.isEmpty { warnNotFound() } else { askPairing(preferred: bridge.pairedId) }
            return
        }
        openedOnce = true
        let url = "http://127.0.0.1:\(LOCAL_PORT)/\(code)/"
        let chrome = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chrome) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", chrome, "--args", "--app=\(url)", "--window-size=1400,900"]
            try? p.run()
        } else if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    func warnNotFound() {
        warned = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Telefon bulunamadı"
        a.informativeText = "Telefonda Dikiz uygulamasını aç ve telefonun Mac ile aynı Wi‑Fi'de olduğundan emin ol.\n\nDikiz menü çubuğunda (göz simgesi) çalışmaya devam ediyor; telefon görününce ekranındaki kodu sorar."
        a.addButton(withTitle: "Tamam")
        a.runModal()
    }
}

@main
enum DikizMain {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
