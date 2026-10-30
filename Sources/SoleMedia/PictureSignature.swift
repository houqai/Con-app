import CoreVideo
import SoleCore

extension PictureCadence {
    public static func signature(of buffer: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, width / 320)
        let columns = width / step, rows = height / step
        guard columns > 0, rows > 0 else { return [] }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        return [UInt8](unsafeUninitializedCapacity: columns * rows) { result, count in
            var index = 0
            for y in 0..<rows {
                var pixel = pixels + (y * step + step / 2) * row + step / 2
                for _ in 0..<columns {
                    result[index] = pixel.pointee
                    index += 1; pixel += step
                }
            }
            count = index
        }
    }
}
