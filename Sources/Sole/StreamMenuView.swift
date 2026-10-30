import SwiftUI
import SoleLogic
import SoleCore
import SoleMedia

struct StreamMenuView: View {
    struct Content {
        var menu: StreamMenu
        var game: StreamGame?
        var stats: StreamStats?
        var statsVisible = false
        var generation = false
        var upscaling = false
        var upscaleAmount = Upscale.Amount.double
        var upscaleMethod = Upscale.Method.fsr
        var battery: (percent: Int, charging: Bool)?
        var fullScreen = false
        var silentSound = false
    }
    let content: Content
    var choose: (StreamMenu.Item) -> Void = { _ in }
    var point: (StreamMenu.Item) -> Void = { _ in }
    var close: () -> Void = {}
    private var fullScreen: Bool { content.fullScreen }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { close() }
            VStack(spacing: 14) {
                panel
                hints
            }.padding(24)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(18)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if content.silentSound {
                Label(loc("The server sent the game without sound"), systemImage: "speaker.slash.fill").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.4)).padding(.horizontal, 18).frame(height: 44)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
            VStack(spacing: 2) {
                ForEach(content.menu.items, id: \.self) { item in row(item) }
            }.padding(8)
        }
        .frame(width: 420)
        .streamGlass(radius: 2 * StreamGlass.radius, opacity: 0.62)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SoleArtwork(url: content.game?.artwork, maxPixels: 320) {
                ZStack { Color.white.opacity(0.06); Image(systemName: "gamecontroller.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.35)) }
            }
            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(StreamGlass.edge)))
            VStack(alignment: .leading, spacing: 6) {
                Text(content.game?.title ?? StreamGame.unknownTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 8) {
                    if let platform = content.game?.platform {
                        Text(platform).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.soleCanvas)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(facts.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                HStack(spacing: 12) {
                    if let stats = content.stats {
                        Label(loc("Playing for %@ min", max(1, stats.seconds / 60)), systemImage: "clock").labelStyle(Fact())
                    }
                    if let battery = content.battery {
                        Label("\(battery.percent)%", systemImage: battery.charging ? "battery.100percent.bolt" : "gamecontroller").labelStyle(Fact())
                    }
                }
                if let stats = content.stats, let delay = stats.delayMs, let ping = stats.livePingMs ?? stats.measuredPingMs {
                    Label(loc("Delay ≈ %@ ms: network %@ + Mac %@", delay, ping, delay - ping), systemImage: "timer").labelStyle(Fact())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var facts: [String] { content.stats?.facts ?? [] }

    private func row(_ item: StreamMenu.Item) -> some View {
        let chosen = content.menu.items.indices.contains(content.menu.selection) && content.menu.items[content.menu.selection] == item
        let leaving = item == .leave
        return Button { choose(item) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon(item)).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(leaving ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                    .frame(width: StreamGlass.button, height: StreamGlass.button)
                    .background((leaving ? Color.red : Color.white).opacity(0.12), in: RoundedRectangle(cornerRadius: StreamGlass.innerRadius, style: .continuous))
                Text(title(item)).font(.system(size: 13, weight: .medium)).foregroundStyle(leaving ? Color(red: 1, green: 0.5, blue: 0.48) : .white)
                Spacer(minLength: 8)
                if let on = state(item) {
                    Text(StreamMenu.Item.stateText(on)).font(.system(size: 12)).foregroundStyle(on ? Color.soleAccent : .white.opacity(0.45))
                } else if let value = item.value(upscaleAmount: content.upscaleAmount, upscaleMethod: content.upscaleMethod) {
                    Text(value).font(.system(size: 12)).foregroundStyle(Color.soleAccent)
                }
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(.white.opacity(chosen ? 0.1 : 0), in: RoundedRectangle(cornerRadius: StreamGlass.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: StreamGlass.radius, style: .continuous).stroke(.white.opacity(chosen ? 0.9 : 0), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { point(item) } }
        .animation(.easeOut(duration: 0.12), value: chosen)
    }

    private func icon(_ item: StreamMenu.Item) -> String {
        switch item {
        case .restart: "arrow.clockwise"
        case .resume: "play.fill"
        case .stats: "chart.bar.fill"
        case .generation: "square.stack.3d.forward.dottedline"
        case .upscaler: "arrow.up.left.and.down.right.magnifyingglass"
        case .upscaleAmount: "plus.magnifyingglass"
        case .upscaleMethod: "wand.and.stars"
        case .fullScreen: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        case .leave: "xmark"
        }
    }
    private func title(_ item: StreamMenu.Item) -> String { item.title(fullScreen: fullScreen) }
    private func state(_ item: StreamMenu.Item) -> Bool? { item.isOn(statsVisible: content.statsVisible, generation: content.generation, upscaling: content.upscaling) }

    private var hints: some View {
        HStack(spacing: 18) {
            hint("✕", loc("Select")); hint("○", loc("Back")); hint("PS", loc("Close"))
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
    }
    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(key).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(title)
        }
    }

    private struct Fact: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) { configuration.icon.font(.system(size: 10, weight: .semibold)); configuration.title.font(.system(size: 12)) }.foregroundStyle(.white.opacity(0.65))
        }
    }
}
