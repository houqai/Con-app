import Foundation

public enum HapticsSound {
    public static let stretch = 16
    public static let rate = 48_000.0
    public static func actuators(_ pcm: Data) -> (left: [Float], right: [Float])? {
        guard pcm.count > 0, pcm.count % 4 == 0 else { return nil }
        let frames = pcm.count / 4
        let bytes = [UInt8](pcm)
        func sample(_ frame: Int, _ channel: Int) -> Float {
            let i = min(frame, frames - 1) * 4 + channel * 2
            return Float(Self.sample(bytes, at: i)) / 32768
        }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames * stretch), count: 2)
        for frame in 0..<(frames * stretch) {
            let source = frame / stretch
            let fraction = Float(frame % stretch) / Float(stretch)
            for channel in 0..<2 {
                let a = sample(source, channel), b = sample(source + 1, channel)
                channels[channel][frame] = a + (b - a) * fraction
            }
        }
        return (channels[0], channels[1])
    }

    public static func motors(_ pcm: Data) -> (left: Double, right: Double)? {
        guard pcm.count > 0, pcm.count % 4 == 0 else { return nil }
        let frames = pcm.count / 4
        var sums = [0.0, 0.0]
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let at = frame * 4 + channel * 2
                    let value = Double(Self.sample(raw, at: at)) / 32768
                    sums[channel] += value * value
                }
            }
        }
        func strength(_ sum: Double) -> Double {
            let loudness = (sum / Double(frames)).squareRoot() * gain
            return loudness < faintest ? 0 : min(1, loudness)
        }
        return (strength(sums[0]), strength(sums[1]))
    }
    static let gain = 4.0, faintest = 0.04
    private static func sample<Bytes: RandomAccessCollection>(_ bytes: Bytes, at index: Int) -> Int16 where Bytes.Element == UInt8, Bytes.Index == Int {
        Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
    }
}
