// DMG penceresinin arka planı: "Dikiz'i Uygulamalar'a sürükle" oku.
// Kullanım: swift make-dmg-bg.swift <çıktı.png>   (1320x800, 660x400 pencerenin @2x hali)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
let W = 1320.0, H = 800.0
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// zemin: koyu, hafif degrade
let bg = NSGradient(starting: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
                    ending: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1))!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

let accent = NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.25, alpha: 1)

// ok: iki simgenin arasında (simgeler y=200 merkezli, x=170 ve x=490; @2x → 340 / 980, y = 800-400)
let y = H - 400
let arrow = NSBezierPath()
arrow.lineWidth = 10
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 520, y: y))
arrow.line(to: NSPoint(x: 790, y: y))
accent.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 820, y: y))
head.line(to: NSPoint(x: 772, y: y + 34))
head.line(to: NSPoint(x: 772, y: y - 34))
head.close()
accent.setFill()
head.fill()

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p,
    ]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.5))
}
text("Dikiz'i Uygulamalar klasörüne sürükle", size: 40, weight: .semibold, color: .white, y: H - 140)
text("Sonra Uygulamalar'dan aç; telefonda Dikiz'i açınca ekrandaki kodu sorar.", size: 26, weight: .regular,
     color: NSColor(calibratedWhite: 0.7, alpha: 1), y: 90)

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
rep.size = NSSize(width: W / 2, height: H / 2)   // 144 dpi → Finder @2x olarak gösterir
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
