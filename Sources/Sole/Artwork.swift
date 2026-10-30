import SwiftUI
import AppKit
import ImageIO
import SoleCore

@MainActor private final class ArtworkStore {
    static let shared = ArtworkStore()
    private static let session = URLSession.lasting(.default)
    private let images = NSCache<NSString, NSImage>()
    private var requests: [String: Task<NSImage?, Never>] = [:]
    private init() { images.totalCostLimit = 48 * 1024 * 1024 }

    func image(url: URL, maxPixels: Int) async -> NSImage? {
        let key = url.absoluteString + "|\(maxPixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if let request = requests[key] { return await request.value }
        let session = Self.session
        let request = Task<NSImage?, Never> {
            do {
                let (data, response) = try await session.plainData(from: url)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
                let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }.value
                guard let decoded else { return nil }
                let image = NSImage(cgImage: decoded, size: .zero)
                images.setObject(image, forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
                return image
            } catch { return nil }
        }
        requests[key] = request
        let image = await request.value
        requests[key] = nil
        return image
    }
}

struct SoleArtwork<Placeholder: View>: View {
    let url: URL?
    var maxPixels: Int = 640
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?
    private var requestID: String { (url?.absoluteString ?? "") + "|\(maxPixels)" }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { placeholder() }
        }.task(id: requestID) {
            image = nil
            guard let url else { return }
            let loaded = await ArtworkStore.shared.image(url: url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
