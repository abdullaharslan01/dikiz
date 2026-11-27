import AVFoundation
import SwiftUI
import UIKit

private let Accent = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x41 / 255)
private let Glass = Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x18 / 255).opacity(0.7)
private let Muted = Color(red: 0xAA / 255, green: 0xB4 / 255, blue: 0xC0 / 255)
private let Live = Color(red: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255)

@main
struct DikizApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.camera)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, p in
            // iOS kamerayı arka planda ve ekran kilitliyken durdurur; ön plana dönünce sürdür.
            if p == .active { model.resume() } else if p == .background { model.pause() }
        }
    }
}

/// Kamera + sunucu + eşleşme kodu.
final class AppModel: ObservableObject {
    let hub = FrameHub()
    let camera: CameraController
    let audio = AudioHub()
    private let server: HttpServer

    @Published var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @Published var denied = false
    @Published var code = Pairing.code()
    @Published var port: UInt16 = 0
    @Published var addresses: [String] = Pairing.localAddresses()
    @Published var clients = 0
    @Published var listeners = 0
    @Published var macSound = false
    private var started = false
    private var addrTimer: Timer?

    init() {
        camera = CameraController(hub: hub)
        server = HttpServer(hub: hub, camera: camera, audio: audio, code: Pairing.code())
        hub.onClientsChanged = { [weak self] n in self?.clients = n }
        audio.onListenersChanged = { [weak self] n in self?.listeners = n }
        server.speaker.onPlayingChanged = { [weak self] on in self?.macSound = on }
    }

    func resume() {
        UIApplication.shared.isIdleTimerDisabled = true   // yayın sürerken ekran kendiliğinden kapanmasın
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.authorized = ok
                    self.denied = !ok
                    if ok { self.begin() }
                }
            }
        default:
            denied = true
        }
        addresses = Pairing.localAddresses()
        if addrTimer == nil {
            addrTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                let a = Pairing.localAddresses()
                if a != self.addresses { self.addresses = a }
            }
        }
    }

    func pause() {
        camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func begin() {
        camera.start()
        // Mikrofonu baştan sor: Mac'ten dinlenmek istendiğinde telefon başında kimse olmayabilir.
        if AVAudioApplication.shared.recordPermission == .undetermined { AudioHub.permission { _ in } }
        if !started {
            started = true
            server.start { [weak self] p in self?.port = p }
        }
    }

    func changeCode() {
        let c = Pairing.regenerate()
        code = c
        server.changeCode(c)
    }
}

// MARK: - Ekran

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @State private var showCode = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = 0.5
    @State private var pinchStart: Double?

    private var prettyCode: String {
        let c = model.code
        guard c.count == 6 else { return c }
        return String(c.prefix(3)) + " " + String(c.suffix(3))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.authorized {
                if camera.ui.phonePreview {
                    CameraPreview(session: camera.session).ignoresSafeArea()
                        .gesture(
                            MagnifyGesture()
                                .onChanged { v in
                                    if pinchStart == nil { pinchStart = camera.ui.zoom }
                                    let z = min(max((pinchStart ?? 1) * v.magnification, camera.ui.zoomMin), camera.ui.zoomMax)
                                    camera.set("zoom", String(format: "%.2f", z))
                                }
                                .onEnded { _ in pinchStart = nil }
                        )
                }
            } else {
                VStack(spacing: 16) {
                    Text(model.denied ? "Dikiz'in kameraya erişmesi gerekiyor." : "Başlatılıyor…")
                        .foregroundStyle(model.denied ? .white : Muted)
                        .multilineTextAlignment(.center)
                    if model.denied {
                        Button("Ayarlarda izin ver") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Accent)
                        .foregroundStyle(.black)
                    }
                }
                .padding(32)
            }

            VStack {
                chip
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
                if let e = camera.ui.error {
                    Text(e).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                    Spacer()
                }
                bottomBar.padding(.bottom, 20)
            }

            if dimmed {
                Color.black.ignoresSafeArea()
                    .overlay(Text("Yayın sürüyor · dokun").font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.17)))
                    .onTapGesture { setDim(false) }
            }
        }
        .statusBarHidden(dimmed)
        .persistentSystemOverlays(dimmed ? .hidden : .automatic)
        .alert("Eşleşme kodu", isPresented: $showCode) {
            Button("Kodu değiştir", role: .destructive) { model.changeCode() }
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("\(prettyCode)\n\nMac'teki Dikiz bu kodu bir kez sorar, sonra bu telefona kendiliğinden bağlanır. " +
                 "Aynı ağdaki başka biri kodu bilmeden kameranı açamaz.\n\n" +
                 "Kodu değiştirirsen bağlı Mac'lerin bağlantısı kesilir ve yeni kodu sorar.")
        }
        .onAppear { model.resume() }
    }

    // ---- Üst: bağlantı rozeti ----
    @ViewBuilder private var chip: some View {
        Button { showCode = true } label: {
            HStack(spacing: 10) {
                if model.clients > 0 || model.listeners > 0 || model.macSound {
                    Circle().fill(Live).frame(width: 8, height: 8)
                    Text("Mac'e bağlı").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if camera.ui.width > 0 && model.clients > 0 {
                        Text("·  \(min(camera.ui.width, camera.ui.height))p · \(Int(camera.ui.fps.rounded())) fps")
                            .font(.system(size: 13)).foregroundStyle(Muted)
                    }
                    if model.macSound {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).foregroundStyle(Accent)
                    }
                    if model.listeners > 0 {
                        Image(systemName: "mic.fill").font(.system(size: 13))
                            .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                    }
                } else if model.port == 0 || model.addresses.isEmpty {
                    Image(systemName: "wifi.slash").foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                    Text("Wi‑Fi'yi aç (Mac ile aynı ağ)").font(.system(size: 14)).foregroundStyle(.white)
                } else {
                    Image(systemName: "laptopcomputer").foregroundStyle(Accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac'te Dikiz'i aç, bu kodu gir")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text(prettyCode)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .tracking(2).foregroundStyle(Accent)
                        Text("\(model.addresses[0]):\(model.port)/\(model.code)")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Muted).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Glass, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: model.clients)
    }

    // ---- Alt: lens seçici + düğmeler ----
    private var bottomBar: some View {
        VStack(spacing: 16) {
            if camera.ui.lensStops.count > 1 {
                HStack(spacing: 4) {
                    ForEach(camera.ui.lensStops, id: \.self) { z in
                        let on = abs(z - camera.ui.zoom) < 0.06 ||
                            (z == camera.ui.lensStops.last(where: { $0 <= camera.ui.zoom + 0.001 }) && !camera.ui.lensStops.contains { abs($0 - camera.ui.zoom) < 0.06 })
                        let shown = on && abs(z - camera.ui.zoom) >= 0.06 ? camera.ui.zoom : z
                        let label = (shown == shown.rounded() ? String(Int(shown)) : String(format: "%.1f", shown)) + (on ? "×" : "")
                        Button { camera.set("zoom", String(z)) } label: {
                            Text(label)
                                .font(.system(size: on ? 14 : 12, weight: .semibold))
                                .foregroundStyle(on ? Accent : .white)
                                .frame(width: 44, height: 44)
                                .background(on ? Color.white.opacity(0.2) : .clear, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Glass, in: Capsule())
            }
            HStack(spacing: 20) {
                if camera.ui.canSwitch {
                    RoundAction(symbol: "arrow.triangle.2.circlepath.camera", label: camera.ui.isFront ? "Arka" : "Ön") {
                        camera.switchCamera()
                    }
                }
                if camera.ui.hasFlash {
                    RoundAction(symbol: "flashlight.on.fill", label: "Işık", active: camera.ui.torch) {
                        camera.set("torch", camera.ui.torch ? "0" : "1")
                    }
                }
                Menu {
                    ForEach(CameraController.qualitySteps, id: \.self) { h in
                        Button { camera.set("preset", String(h)) } label: {
                            if h == camera.currentQuality() { Label("\(h)p", systemImage: "checkmark") } else { Text("\(h)p") }
                        }
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "dial.medium")
                            .font(.system(size: 22)).foregroundStyle(.white)
                            .frame(width: 58, height: 58).background(Glass, in: Circle())
                        Text("\(camera.currentQuality())p").font(.system(size: 12)).foregroundStyle(.white)
                    }
                }
                RoundAction(symbol: "moon.fill", label: "Karart") { setDim(true) }
            }
        }
    }

    private func setDim(_ on: Bool) {
        if on {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.01
        } else {
            UIScreen.main.brightness = savedBrightness
        }
        dimmed = on
    }
}

private struct RoundAction: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(active ? .black : .white)
                    .frame(width: 58, height: 58)
                    .background(active ? Accent : Glass, in: Circle())
            }
            .buttonStyle(.plain)
            Text(label).font(.system(size: 12)).foregroundStyle(.white)
        }
    }
}

/// Telefon ekranındaki canlı önizleme (arayüz hep dik).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        if let c = v.previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        if let c = v.previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90
        }
    }
}
