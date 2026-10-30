import SwiftUI
import SoleLogic
import SoleCore

struct SoleGameGallery: View {
    let game: Game
    var thumbnailHeight: CGFloat = 180
    var availableWidth: CGFloat = 1000
    @EnvironmentObject private var model: SoleModel
    @EnvironmentObject private var focus: ControllerFocus
    @State private var screenshots: [URL] = []
    private var requestID: String { "\(model.catalogLocale)|\(game.id)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !screenshots.isEmpty {
                Text(loc("Screenshots")).font(.system(size: 18, weight: .semibold))
                let columns = min(screenshots.count, availableWidth > 1000 ? 6 : availableWidth > 700 ? 4 : 3)
                let rows = (screenshots.count + columns - 1) / columns
                let width = min((availableWidth - CGFloat(columns - 1) * 16) / CGFloat(columns), max(40, (thumbnailHeight - CGFloat(rows - 1) * 16) / CGFloat(rows)) * 16 / 9)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 16), count: columns), alignment: .leading, spacing: 16) {
                    ForEach(screenshots.indices, id: \.self) { index in
                        let target = "screenshot:\(index)"
                        Button { focus.selected = target } label: {
                            SoleArtwork(url: screenshots[index], maxPixels: 640) { Color.soleSurface }
                                .frame(width: width, height: width * 9 / 16).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel(loc("Screenshot %@", index + 1))
                            .controllerTarget(target) { focus.selected = target }
                    }
                }.padding(.vertical, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).task(id: requestID) {
            screenshots = []
            let result = await model.screenshots(for: game)
            guard !Task.isCancelled else { return }
            screenshots = result
        }
    }
}
