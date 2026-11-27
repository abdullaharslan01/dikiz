import Foundation
import Security
import UIKit

/// Eşleşme kodu ve telefon kimliği — Android'deki DikizService ile aynı mantık.
///  - Kod 6 hanelidir, yalnızca ekranda görünür (Bonjour ilanında yoktur), kalıcıdır.
///  - Kimlik gizli değildir; Mac aynı ağdaki telefonları bununla ayırır.
enum Pairing {
    private static let d = UserDefaults.standard

    static func code() -> String {
        if let c = d.string(forKey: "pin") { return c }
        let c = newPin()
        d.set(c, forKey: "pin")
        return c
    }

    /// Yeni kod üret ve kaydet (bağlı Mac'ler yeni kodu ister).
    static func regenerate() -> String {
        let c = newPin()
        d.set(c, forKey: "pin")
        return c
    }

    private static func newPin() -> String {
        var digits = ""
        for _ in 0..<6 {
            var b: UInt32 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &b)
            digits += String(b % 10)
        }
        return digits
    }

    static func deviceId() -> String {
        if let i = d.string(forKey: "id") { return i }
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let i = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(i, forKey: "id")
        return i
    }

    /// "iPhone17,1" gibi model kimliği.
    static func modelIdentifier() -> String {
        var s = utsname()
        uname(&s)
        let id = withUnsafeBytes(of: &s.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id.isEmpty ? "iPhone" : id
    }

    /// Mac menüsünde görünen ad. iOS 16'dan beri uygulamalar cihaz adını değil yalnızca
    /// "iPhone" görür; aynı ağda iki iPhone ayırt edilsin diye kimliğin başını ekleriz.
    static func deviceName() -> String {
        let n = UIDevice.current.name
        let model = UIDevice.current.model
        if n.isEmpty || n == model { return "\(model) · \(deviceId().prefix(4))" }
        return n
    }

    /// Telefonun yerel ağdaki IPv4 adresleri (Wi‑Fi önce).
    static func localAddresses() -> [String] {
        var out: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let lan = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
                    if lan && (name.hasPrefix("en") || name.hasPrefix("bridge")) { out.append((name, ip)) }
                }
            }
            p = ifa.ifa_next
        }
        let sorted = out.sorted { ($0.0 == "en0" ? 0 : 1) < ($1.0 == "en0" ? 0 : 1) }
        var seen = Set<String>()
        return sorted.map(\.1).filter { seen.insert($0).inserted }
    }
}
