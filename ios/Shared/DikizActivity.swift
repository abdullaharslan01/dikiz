import ActivityKit
import AppIntents
import Foundation

/// Dynamic Island ve kilit ekranında görünen canlı durum (Live Activity).
struct DikizAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var live: Bool          // kamera yayında mı (uygulama önde)
        var connected: Bool     // Mac'e bağlı mı
        var mic: Bool           // mikrofon dinleniyor mu
        var macSound: Bool      // Mac'in sesi çalıyor mu
        var quality: Int        // 1080 / 720 / ...
    }
}

extension Notification.Name {
    static let dikizStop = Notification.Name("app.dikiz.stop")
}

/// Dynamic Island'daki "Kapat" düğmesi: yayını durdurur ve canlı etkinliği bitirir.
struct StopDikizIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dikiz'i kapat"
    static var description = IntentDescription("Dikiz yayınını durdurur.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: .dikizStop, object: nil) }
        for a in Activity<DikizAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        return .result()
    }
}
