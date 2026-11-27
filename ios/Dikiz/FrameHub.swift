import Foundation

/// Kamera ile HTTP istemcileri arasında en son JPEG karesini paylaşır (Android FrameHub karşılığı).
final class FrameHub {
    struct Frame {
        let seq: Int
        let jpeg: Data
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var seq = 0
    private var _latest: Frame?
    private var subscribers: [UUID: (Frame) -> Void] = [:]
    private var streamClients = 0
    private var demandUntil = Date.distantPast

    /// İzleyici sayısı değişince (ana iş parçacığında) çağrılır.
    var onClientsChanged: ((Int) -> Void)?

    var latest: Frame? { lock.lock(); defer { lock.unlock() }; return _latest }
    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return streamClients }

    /// Kodlamayı yalnızca birisi izliyorsa yap (pil ve ısı için).
    func wantsFrames() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !subscribers.isEmpty || Date() < demandUntil
    }

    func requestFrames(for seconds: TimeInterval) {
        lock.lock(); demandUntil = Date().addingTimeInterval(seconds); lock.unlock()
    }

    /// Canlı yayın izleyicisi ekle; her yeni karede `onFrame` çağrılır.
    func subscribe(stream: Bool, _ onFrame: @escaping (Frame) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = onFrame
        if stream { streamClients += 1 }
        let n = streamClients
        lock.unlock()
        if stream { DispatchQueue.main.async { self.onClientsChanged?(n) } }
        return id
    }

    func unsubscribe(_ id: UUID, stream: Bool) {
        lock.lock()
        let existed = subscribers.removeValue(forKey: id) != nil
        if existed && stream { streamClients -= 1 }
        let n = streamClients
        lock.unlock()
        if existed && stream { DispatchQueue.main.async { self.onClientsChanged?(n) } }
    }

    func publish(jpeg: Data, width: Int, height: Int) {
        lock.lock()
        seq += 1
        let f = Frame(seq: seq, jpeg: jpeg, width: width, height: height)
        _latest = f
        let subs = Array(subscribers.values)
        lock.unlock()
        subs.forEach { $0(f) }
    }

    /// Bir sonraki kareyi bekler (en çok `timeout` sn); gelmezse eldeki son kare.
    func nextFrame(timeout: TimeInterval, queue: DispatchQueue, _ done: @escaping (Frame?) -> Void) {
        requestFrames(for: 3)
        var finished = false
        let doneLock = NSLock()
        var subId: UUID?
        let finish: (Frame?) -> Void = { [weak self] f in
            doneLock.lock()
            if finished { doneLock.unlock(); return }
            finished = true
            let id = subId
            doneLock.unlock()
            if let id { self?.unsubscribe(id, stream: false) }
            queue.async { done(f) }
        }
        let id = subscribe(stream: false) { f in finish(f) }
        doneLock.lock()
        subId = id
        let already = finished
        doneLock.unlock()
        if already { unsubscribe(id, stream: false) }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in finish(self?.latest) }
    }
}
