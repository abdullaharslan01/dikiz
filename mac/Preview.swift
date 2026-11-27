// Menü çubuğu önizlemesi: göz simgesine basınca menünün en üstünde küçük, canlı bir ayna.
// Yalnızca menü açıkken telefondan görüntü çeker (127.0.0.1:47801/stream, kodsuz yerel besleme).
import Cocoa

/// MJPEG (multipart/x-mixed-replace) akışını karelere ayırır; X-Rotation başlığını da okur.
final class MJPEGReader: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var buffer = Data()
    var onFrame: ((NSImage, Int) -> Void)?

    func start(_ url: URL) {
        stop()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        s.dataTask(with: url).resume()
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
    }

    // URLSession multipart/x-mixed-replace akışını kendisi parçalara ayırır: her kare için yeni bir
    // yanıt (başlıklar orada) ve yalnızca JPEG gövdesi gelir. Başlıksız ham akış için parse() yedekte.
    private var partMode = false
    private var partRotation = 0

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse {
            let type = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.hasPrefix("image/") {
                partMode = true
                emitPart()
                partRotation = Int(h.value(forHTTPHeaderField: "X-Rotation") ?? "") ?? 0
            }
        }
        completionHandler(.allow)
    }

    private func emitPart() {
        guard partMode, !buffer.isEmpty else { return }
        if let img = NSImage(data: buffer) { onFrame?(img, partRotation) }
        buffer.removeAll(keepingCapacity: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if partMode {
            // JPEG bitişi (FF D9) geldiyse kareyi beklemeden göster
            if buffer.count > 2, buffer[buffer.endIndex - 2] == 0xFF, buffer[buffer.endIndex - 1] == 0xD9 { emitPart() }
        } else {
            parse()
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }   // bozuk akışta bellek şişmesin
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Telefon değişti ya da bağlantı koptu: menü hâlâ açıksa kısa süre sonra yeniden dene.
        guard self.session === session, let url = task.originalRequest?.url else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.session === session else { return }
            self.start(url)
        }
    }

    private func parse() {
        let sep = Data("\r\n\r\n".utf8)
        while let headEnd = buffer.range(of: sep) {
            let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
            var length = -1, rotation = 0
            for line in head.split(separator: "\r\n") {
                let l = line.lowercased()
                if l.hasPrefix("content-length:") { length = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? -1 }
                if l.hasPrefix("x-rotation:") { rotation = Int(l.dropFirst(11).trimmingCharacters(in: .whitespaces)) ?? 0 }
            }
            guard length > 0 else {
                // HTTP yanıt başlığı ya da sınır satırı: atla
                buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)
                continue
            }
            let bodyStart = headEnd.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return }
            let jpeg = buffer.subdata(in: bodyStart..<(bodyStart + length))
            buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
            if let img = NSImage(data: jpeg) { onFrame?(img, rotation) }
        }
    }
}

/// Menü öğesinin içindeki önizleme görünümü (tıklayınca büyük izleme penceresi açılır).
final class PreviewView: NSView {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "Telefon bekleniyor…")
    private let reader = MJPEGReader()
    var onClick: (() -> Void)?
    /// Sanal kameranın yön ayarlarını önizlemeye de uygula (ayna gibi görünsün).
    var mirror = false
    var extraRotation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let box = NSView(frame: bounds.insetBy(dx: 12, dy: 6))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.cgColor
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        box.autoresizingMask = [.width, .height]
        addSubview(box)
        imageView.frame = box.bounds
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        box.addSubview(imageView)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: box.bounds.midY - 9, width: box.bounds.width, height: 18)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        box.addSubview(label)
        reader.onFrame = { [weak self] img, rot in
            DispatchQueue.main.async { self?.show(img, rotation: rot) }
        }
        toolTip = "Büyük görüntüyü aç"
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        label.stringValue = "Görüntü bekleniyor…"
        label.isHidden = false
        if let u = URL(string: "http://127.0.0.1:\(LOCAL_PORT + 1)/stream") { reader.start(u) }
    }

    func stop() { reader.stop() }

    func setWaiting(_ text: String) {
        stop()
        imageView.image = nil
        label.stringValue = text
        label.isHidden = false
    }

    private func show(_ img: NSImage, rotation: Int) {
        label.isHidden = true
        imageView.image = transform(img, degrees: (rotation + extraRotation) % 360, mirror: mirror)
    }

    /// Döndür (90'ın katları) ve gerekirse aynala.
    private func transform(_ img: NSImage, degrees: Int, mirror: Bool) -> NSImage {
        guard degrees != 0 || mirror else { return img }
        let w = img.size.width, h = img.size.height
        let swap = degrees == 90 || degrees == 270
        let out = NSImage(size: swap ? NSSize(width: h, height: w) : img.size)
        out.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: out.size.width / 2, yBy: out.size.height / 2)
        t.rotate(byDegrees: CGFloat(-degrees))
        if mirror { t.scaleX(by: -1, yBy: 1) }
        t.translateX(by: -w / 2, yBy: -h / 2)
        t.concat()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        out.unlockFocus()
        return out
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onClick?()
    }
}
