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

    private(set) var target: NWEndpoint?
    private(set) var code: String?
    private(set) var model: String?
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
            if let r = results.first {
                self.target = r.endpoint
                if case let .bonjour(txt) = r.metadata {
                    self.code = txt["code"]
                    self.model = txt["model"]
                }
            } else {
                self.target = nil
            }
            self.notify()
        }
        b.start(queue: q)
        browser = b
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

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

final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    let bridge = Bridge()
    var item: NSStatusItem!
    var openedOnce = false
    var warned = false
    var cameraStatus = "Toplantı kamerası kuruluyor…"
    var cameraReady = false
    var approvalAlertShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Dikiz")
        bridge.onChange = { [weak self] in self?.refresh(); self?.pollPhone() }
        bridge.vcamConfig = {
            let d = UserDefaults.standard
            func b(_ k: String) -> Int { d.bool(forKey: k) ? 1 : 0 }
            return "mirror=\(b("vcamMirror"));flip=\(b("vcamFlip"));rot=\(d.integer(forKey: "vcamRot"))" +
                ";blur=\(b("fxBlur"));beauty=\(b("fxBeauty"))" +
                ";filter=\(d.string(forKey: "fxFilter") ?? "none")"
        }
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

    func refresh() {
        let menu = NSMenu()
        let status: String
        if let e = bridge.listenError {
            status = "Hata: \(e)"
        } else if bridge.code != nil {
            status = "● \(bridge.model ?? "Telefon") bağlı"
        } else {
            status = "○ Telefon aranıyor…"
        }
        let s = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Görüntüyü aç", action: #selector(openViewerAction), keyEquivalent: "o")
        open.target = self
        open.isEnabled = bridge.code != nil
        menu.addItem(open)
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

    // ---- telefon durumu (lens / ışık) ----
    var phoneLensStops: [Double] = []
    var phoneZoom: Double = 1
    var phoneTorch = false
    var phoneHasFlash = false

    func pollPhone() {
        guard let code = bridge.code,
              let u = URL(string: "http://127.0.0.1:\(LOCAL_PORT)/\(code)/api/state") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let stops = (j["lensStops"] as? [Double]) ?? []
                let zoom = (j["zoom"] as? Double) ?? 1
                let torch = (j["torch"] as? Bool) ?? false
                let flash = (j["hasFlash"] as? Bool) ?? false
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

    func openViewer() {
        guard let code = bridge.code else { warnNotFound(); return }
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
        a.informativeText = "Telefonda Dikiz uygulamasını aç ve telefonun Mac ile aynı Wi‑Fi'de olduğundan emin ol.\n\nDikiz menü çubuğunda (göz simgesi) çalışmaya devam ediyor; telefon görünür görünmez görüntü açılır."
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
