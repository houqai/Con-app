import SwiftUI
import SoleCore
import SoleLogic
import AppKit

struct SoleGameCover: View {
    let game: Game
    var body: some View {
        SoleArtwork(url: game.artworkURL) { Color.soleHue(game.hue).overlay(Image(systemName: "gamecontroller").font(.system(size: 32)).opacity(0.6)) }.aspectRatio(1, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
struct SoleGameCard: View {
    @EnvironmentObject private var model: SoleModel
    @EnvironmentObject private var focus: ControllerFocus
    let game: Game
    @Environment(\.isEnabled) private var enabled
    private var selected: Bool { enabled && focus.isFocused(LibraryScreen.Target.game(game.id)) }
    var body: some View {
        SoleGameCover(game: game)
            .overlay(alignment: .bottomLeading) {
                Text(game.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)).clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
            }.contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil); model.openGame(game) }
            .overlay(alignment: .topTrailing) {
                Button { model.toggleFavorite(game.id) } label: { Image(systemName: game.favorite ? "star.fill" : "star").font(.system(size: 13)).frame(width: 28, height: 28).background(.black.opacity(0.35), in: Circle()) }.buttonStyle(.plain).padding(8).help(game.favorite ? loc("Remove from favorites") : loc("Add to favorites"))
            }
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.soleCanvas, lineWidth: 3).padding(-3).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 3).padding(-6)).opacity(selected ? 1 : 0).animation(nil, value: selected))
            .shadow(color: .black.opacity(selected ? 0.45 : 0.2), radius: selected ? 12 : 4, y: selected ? 8 : 3).scaleEffect(selected ? 1.06 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selected)
            .controllerTarget(LibraryScreen.Target.game(game.id)) { model.openGame(game) }
            .accessibilityElement(children: .contain).accessibilityLabel(game.title).accessibilityAddTraits(.isButton)
    }
}
