import Foundation

public enum VideoCaptureChoice {
    public static let settingKey = "sole.videoCapture"
    public static let environmentKey = "CON_VIDEO_CAPTURE"
    public static let fileName = "video-capture.bin"
    public static let audioFileName = "audio-capture.bin"

    public static func resolve(environment: [String: String], setting: Bool) -> Bool {
        switch environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return setting
        }
    }
}
