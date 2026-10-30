import Foundation

public struct LossGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case decode
        case skip
    }

    private var last: Int?
    private var started = false
    private var picture = false
    private var configured = false
    private var configures = false
    public private(set) var missing = 0
    public private(set) var parametersFirst: [[UInt8]] = []

    public init() {}

    public mutating func restart() { started = false; configured = false }

    public mutating func take(_ unit: VideoStream.Unit, of stream: VideoStream, frame: Int?) -> Decision {
        take(unit, parameterSets: stream.parameterSets, frame: frame)
    }

    public mutating func take(_ unit: VideoStream.Unit, parameterSets: [[UInt8]]? = nil, frame: Int?) -> Decision {
        picture = unit.hasPicture
        missing = 0
        parametersFirst = []
        configures = unit.carriesParameters
        if let frame, let last {
            let gap = (frame - last) & 0xFFFF
            if gap > 1, gap < 0x8000 { missing = gap - 1 }
        }
        if frame != nil { last = frame }
        guard unit.hasPicture else { return .decode }
        if unit.isKeyframe {
            if !configured, !unit.carriesParameters, let parameterSets {
                parametersFirst = parameterSets
                configures = true
            }
            started = true
            return .decode
        }
        return started ? .decode : .skip
    }

    public mutating func decoded(_ taken: Bool) {
        if configures, taken { configured = true }
        configures = false
        guard picture else { return }
        if !taken { started = false }
    }
}
