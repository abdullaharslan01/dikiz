import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let Accent = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x41 / 255)

@main
struct DikizLiveBundle: WidgetBundle {
    var body: some Widget { DikizLiveWidget() }
}

struct DikizLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DikizAttributes.self) { ctx in
            // Kilit ekranı
            HStack(spacing: 12) {
                Image(systemName: "eye.fill").font(.title2).foregroundStyle(Accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(ctx.state)).font(.headline)
                    Text(detail(ctx.state)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: StopDikizIntent()) {
                    Label("Kapat", systemImage: "power").labelStyle(.iconOnly)
                }
                .tint(.red)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.75))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Dikiz", systemImage: "eye.fill").foregroundStyle(Accent).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopDikizIntent()) { Label("Kapat", systemImage: "power") }
                        .tint(.red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(title(ctx.state)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(detail(ctx.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "eye.fill").foregroundStyle(Accent)
            } compactTrailing: {
                HStack(spacing: 3) {
                    if ctx.state.mic { Image(systemName: "mic.fill").foregroundStyle(.red) }
                    if ctx.state.macSound { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Accent) }
                    Circle().fill(ctx.state.live && ctx.state.connected ? Color.green : Color.gray).frame(width: 7, height: 7)
                }
            } minimal: {
                Image(systemName: "eye.fill").foregroundStyle(Accent)
            }
        }
    }

    private func title(_ s: DikizAttributes.ContentState) -> String {
        if !s.live { return "Dikiz duraklatıldı" }
        return s.connected ? "Mac'e bağlı" : "Dikiz açık"
    }

    private func detail(_ s: DikizAttributes.ContentState) -> String {
        if !s.live { return "Devam etmek için dokun" }
        var p: [String] = []
        if s.connected { p.append("\(s.quality)p") }
        if s.mic { p.append("mikrofon") }
        if s.macSound { p.append("Mac sesi") }
        return p.isEmpty ? "Mac'te kodu gir" : p.joined(separator: ", ")
    }
}
