// İlk kurulum rehberi: kamera izni, ses sürücüsü ve telefonla eşleşme tek pencerede, adım adım.
// İlk açılışta kendiliğinden çıkar; menüden "Kurulum rehberi…" ile yeniden açılır.
import Cocoa
import SwiftUI

final class SetupModel: ObservableObject {
    enum Step: Equatable { case waiting, needsAction, working, done, failed(String) }

    @Published var camera: Step = .waiting
    @Published var driver: Step = .needsAction
    @Published var pairing: Step = .needsAction
    @Published var phoneCount = 0
    @Published var pairedName: String?
    @Published var code = ""

    // AppDelegate'in bağladığı eylemler
    var openCameraSettings: () -> Void = {}
    var retryCamera: () -> Void = {}
    var installDriver: (@escaping (String?) -> Void) -> Void = { _ in }
    var pair: (String, @escaping (Bool, String?) -> Void) -> Void = { _, _ in }
    var finish: () -> Void = {}

    func refreshDriver() {
        switch MicDriver.status {
        case .ok: driver = .done
        case .missing, .outdated: if driver != .working { driver = .needsAction }
        }
    }

    var allDone: Bool { camera == .done && driver == .done && pairing == .done }
}

private let Accent = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x41 / 255)

struct SetupView: View {
    @ObservedObject var m: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dikiz kurulumu").font(.system(size: 22, weight: .bold))
                    Text("Üç adımda telefonun Mac'te kamera, mikrofon ve hoparlör olur.")
                        .foregroundStyle(.secondary)
                }
            }

            StepRow(n: 1, title: "Dikiz Kamera'ya izin ver",
                    detail: cameraDetail, state: m.camera) {
                switch m.camera {
                case .failed: Button("Tekrar dene") { m.retryCamera() }
                case .done: EmptyView()
                default: Button("Ayarları aç") { m.openCameraSettings() }.keyboardShortcut(.defaultAction)
                }
            }

            StepRow(n: 2, title: "Ses sürücüsünü kur",
                    detail: "Dikiz Mikrofon: telefonun mikrofonu toplantıda mikrofon olur. Dikiz Hoparlör: Mac'in sesi telefondan çıkar. Mac şifren bir kez sorulur.",
                    state: m.driver) {
                if m.driver != .done {
                    Button(m.driver == .working ? "Kuruluyor…" : "Kur") {
                        m.driver = .working
                        m.installDriver { err in
                            if let err, !err.isEmpty { m.driver = .failed(err) } else if err != nil { m.driver = .needsAction } else { m.driver = .done }
                        }
                    }
                    .disabled(m.driver == .working)
                }
            }

            StepRow(n: 3, title: m.pairedName.map { "Eşleşti: \($0)" } ?? "Telefonu eşleştir",
                    detail: pairingDetail, state: m.pairing) {
                if m.pairing != .done {
                    HStack(spacing: 8) {
                        TextField("Kod", text: $m.code)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .frame(width: 110)
                            .onSubmit(doPair)
                        Button(m.pairing == .working ? "Bakılıyor…" : "Eşleştir", action: doPair)
                            .disabled(m.code.filter(\.isNumber).count < 4 || m.pairing == .working || m.phoneCount == 0)
                    }
                }
            }

            HStack {
                Text(m.allDone ? "Hazırsın. Toplantıda Dikiz Kamera ve Dikiz Mikrofon'u seç." : "Adımları sonra menüdeki göz simgesinden de tamamlayabilirsin.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(m.allDone ? "Bitir" : "Sonra") { m.finish() }
                    .keyboardShortcut(m.allDone ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var cameraDetail: String {
        switch m.camera {
        case .done: return "Zoom, Meet, Teams ve FaceTime'da “Dikiz Kamera” olarak görünür."
        case .failed(let e): return e
        default: return "Açılan Sistem Ayarları'nda Genel → Giriş Öğeleri ve Uzantılar → Kamera Uzantıları altında Dikiz'i aç. Onay verince bu adım kendiliğinden tamamlanır."
        }
    }

    private var pairingDetail: String {
        if m.pairing == .done { return "Mac bundan sonra yalnızca bu telefona bağlanır." }
        if case .failed(let e) = m.pairing { return e }
        if m.phoneCount == 0 { return "Telefonda Dikiz'i aç; telefon ve Mac aynı Wi‑Fi'de olsun. Telefon aranıyor…" }
        return "Telefonda Dikiz ekranının üstündeki 6 haneli kodu yaz."
    }

    private func doPair() {
        let c = m.code.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !c.isEmpty else { return }
        m.pairing = .working
        m.pair(c) { ok, name in
            if ok { m.pairing = .done; m.pairedName = name } else { m.pairing = .failed("Kod tutmadı. Telefondaki kodu kontrol et.") }
        }
    }
}

private struct StepRow<Actions: View>: View {
    let n: Int
    let title: String
    let detail: String
    let state: SetupModel.Step
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(state == .done ? Color.green.opacity(0.85) : Accent.opacity(0.2)).frame(width: 30, height: 30)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else if state == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Accent)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12))
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }
}

/// Pencereyi tutan küçük denetleyici.
final class SetupWindow: NSObject, NSWindowDelegate {
    let model = SetupModel()
    private var window: NSWindow?
    var isOpen: Bool { window != nil }
    var onClose: () -> Void = {}

    func show() {
        model.refreshDriver()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(m: model)))
        w.title = "Dikiz kurulumu"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}
