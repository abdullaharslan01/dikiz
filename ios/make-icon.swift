// iOS uygulama simgesi: Mac simgesiyle aynı çizim (dikiz aynası içinde göz), ama kenarsız
// kare ve saydamlıksız (App Store saydam simgeyi kabul etmez; köşeleri iOS kendisi yuvarlar).
// Kullanım: swift make-icon.swift <çıktı.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

c(0x1F2A37).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

// Mac simgesindeki içerik 824 px'lik kareye çiziliyordu; burada tüm kareyi doldursun.
let t = NSAffineTransform()
t.translateX(by: size / 2, yBy: size / 2)
t.scale(by: 1.18)
t.translateX(by: -size / 2, yBy: -size / 2 + 20)
t.concat()

c(0x8A96A8).setFill()
NSBezierPath(rect: NSRect(x: 482, y: 640, width: 60, height: 110)).fill()
let frame = NSRect(x: 230, y: 330, width: 564, height: 330)
c(0xF5B841).setFill(); NSBezierPath(roundedRect: frame, xRadius: 90, yRadius: 90).fill()
c(0x111827).setFill(); NSBezierPath(roundedRect: frame.insetBy(dx: 34, dy: 34), xRadius: 62, yRadius: 62).fill()
let eye = NSBezierPath()
eye.move(to: NSPoint(x: 330, y: 495))
eye.curve(to: NSPoint(x: 694, y: 495), controlPoint1: NSPoint(x: 420, y: 625), controlPoint2: NSPoint(x: 604, y: 625))
eye.curve(to: NSPoint(x: 330, y: 495), controlPoint1: NSPoint(x: 604, y: 365), controlPoint2: NSPoint(x: 420, y: 365))
c(0xFFFFFF).setFill(); eye.fill()
c(0x1F2A37).setFill(); NSBezierPath(ovalIn: NSRect(x: 452, y: 435, width: 120, height: 120)).fill()
c(0xFFFFFF).setFill(); NSBezierPath(ovalIn: NSRect(x: 520, y: 500, width: 34, height: 34)).fill()

NSGraphicsContext.restoreGraphicsState()

// Saydamlık kanalını at: RGB (noneSkipLast) bağlamına çizip öyle kaydet.
let cg = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
cg.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
let opaque = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
