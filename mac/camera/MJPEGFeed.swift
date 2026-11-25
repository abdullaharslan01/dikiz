// Dikiz Mac uygulamasının 127.0.0.1:47801 beslemesinden MJPEG okur, son kareyi çözüp tutar.
import Foundation
import Network
import ImageIO
import CoreGraphics

final class MJPEGFeed {
    struct Frame { let image: CGImage; let rotation: Int; let at: Date }

    private let q = DispatchQueue(label: "dikiz.feed", qos: .userInteractive)
    private let lock = NSLock()
    private var conn: NWConnection?
    private var buffer = Data()
    private var headerDone = false
    private var running = false
    private var _latest: Frame?

    var latest: Frame? { lock.lock(); defer { lock.unlock() }; return _latest }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    func stop() {
        q.async {
            self.running = false
            self.conn?.cancel()
            self.conn = nil
        }
    }

    private func connect() {
        guard running else { return }
        buffer.removeAll(keepingCapacity: true)
        headerDone = false
        let c = NWConnection(host: "127.0.0.1", port: 47801, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                let req = "GET /stream?src=camera HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
                c.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                self.read(c)
            case .failed, .cancelled:
                self.retry(c)
            default: break
            }
        }
        c.start(queue: q)
    }

    private func retry(_ c: NWConnection) {
        guard conn === c else { return }
        conn = nil
        guard running else { return }
        q.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect() }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if done || err != nil {
                c.cancel()
                self.retry(c)
            } else {
                self.read(c)
            }
        }
    }

    private static let crlf2 = Data("\r\n\r\n".utf8)

    private func parse() {
        if !headerDone {
            guard let r = buffer.range(of: Self.crlf2) else { return }
            let head = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<r.upperBound)
            guard head.hasPrefix("HTTP/1.1 200") else { conn?.cancel(); return }
            headerDone = true
        }
        while true {
            guard let r = buffer.range(of: Self.crlf2) else { return }
            let head = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
            var length = -1
            var rotation = 0
            for line in head.split(separator: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") { length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? -1 }
                if lower.hasPrefix("x-rotation:") { rotation = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
            }
            guard length > 0 else { buffer.removeSubrange(..<r.upperBound); continue }
            let start = r.upperBound
            guard buffer.count - (start - buffer.startIndex) >= length else { return }
            let jpeg = buffer.subdata(in: start..<(start + length))
            buffer.removeSubrange(..<(start + length))
            decode(jpeg, rotation: rotation)
        }
    }

    private func decode(_ jpeg: Data, rotation: Int) {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return }
        lock.lock()
        _latest = Frame(image: img, rotation: rotation, at: Date())
        lock.unlock()
    }
}
