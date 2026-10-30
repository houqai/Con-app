import Foundation

public enum GenerationState: Sendable, Equatable {
    case off, standby, preparing, active, unavailable
    public static let defaultHeight = 720
}

public struct VideoStats: Sendable {
    public init() {}
    public var receivedFrames = 0
    public var newFrames = 0
    public var lastChange = 0.0
    public var codec: UInt32 = 0
    public var hardwareDecoder: Bool?
    public var shownFrames = 0
    public var generatedFrames = 0
    public var decodeFailures = 0
    public var lateFrames = 0
    public var missingFrames = 0
    public var suppressedRepeats = 0
    public var keyframes = 0
    public var bridgedLosses = 0
    public var hiddenFrames = 0
    public var bytes = 0
    public var width = 0
    public var height = 0
    public var decodeMs = 0.0
    public var generationMs = 0.0
    public var addedDelayMs = 0.0
    public var generation = GenerationState.off
    public var presentationMs = 0.0
    public var prepareQueueMs = 0.0
    public var deliveryMs = 0.0
    public var maxDeliveryMs = 0.0
    public var queueDrops = 0
    public var upscaledHeight = 0
    public var shownAtHandOver = false

    public func screenDelayMs(displayRate: Double) -> Double {
        let refresh = 1000 / (displayRate > 0 ? displayRate : 60)
        if shownAtHandOver { return decodeMs + deliveryMs + refresh * 1.4 + refresh / 2 + 2 + addedDelayMs }
        return decodeMs + max(presentationMs + refresh / 2 + 2, refresh * 1.4) + addedDelayMs
    }
}
