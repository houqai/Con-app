import Android
import CConAndroid
import CConAndroidCheck
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleAndroid
import SoleCore
import SoleEngine
import SoleLogic

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ what: String, _ passed: Bool, _ detail: String = "") {
    print((passed ? "ok    " : "FAIL  ") + what + (detail.isEmpty ? "" : " — " + detail))
    if !passed { failures += 1 }
}

check("the engine starts", SoleEngine.initialize())

let name = "con.check." + UUID().uuidString
if let defaults = UserDefaults(suiteName: name) {
    var layout = KeyboardLayout.standard
    layout.assign(Key.enter, to: .cross)
    layout.store(in: defaults)
    check("a setting is stored and read back", KeyboardLayout.stored(in: defaults).keys[.cross] == Key.enter)
    UserDefaults().removePersistentDomain(forName: name)
} else {
    check("a setting is stored and read back", false, "no settings store")
}

check("texts follow the chosen language", Localization.text("Space") == "Space" && Key.name(Key.enter) == "Enter")

let httpsBeforeRoots = try? await StoreScreenshotService().screenshots(conceptID: 234567, locale: "en-us")
print("note  HTTPS before installing the system root certificates: " + (httpsBeforeRoots == nil ? "refused" : "works"))
let roots = AndroidCertificates.install(in: FileManager.default.temporaryDirectory)
check("the system root certificates are collected", roots > 50, "\(roots) certificates")

do {
    let started = Date()
    let screenshots = try await StoreScreenshotService().screenshots(conceptID: 234567, locale: "en-us")
    let took = Int(Date().timeIntervalSince(started) * 1000)
    check("Sony's store answers over HTTPS", !screenshots.isEmpty, "\(screenshots.count) screenshots in \(took) ms, first from \(screenshots.first?.host ?? "-")")
} catch {
    check("Sony's store answers over HTTPS", false, "\(error)")
}

do {
    let started = Date()
    let catalog = try await CloudCatalogService().load(locale: "en-us", force: true)
    let took = Int(Date().timeIntervalSince(started) * 1000)
    check("the cloud game catalog loads", catalog.titles.count > 1000, "\(catalog.titles.count) games in \(took) ms, first: \(catalog.titles.first?.name ?? "-")")
} catch {
    check("the cloud game catalog loads", false, "\(error)")
}

final class Units { var list: [(bytes: [UInt8], parameters: Bool)] = [] }
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var times: Int { lock.withLock { count } }
}
func give(_ media: AndroidMedia, _ bytes: [UInt8], display: Bool = true) -> Bool { bytes.withUnsafeBufferPointer { media.video($0, frame: 0, display: display) } }
@discardableResult
func feed(_ media: AndroidMedia, _ units: some Sequence<[UInt8]>, display: (Int) -> Bool = { _ in true }) -> Int {
    var taken = 0
    for (index, unit) in units.enumerated() {
        if give(media, unit, display: display(index)) { taken += 1 }
        Thread.sleep(forTimeInterval: 0.008)
    }
    return taken
}
func pictures(_ media: AndroidMedia, atLeast wanted: Int) -> Int {
    let until = Date().addingTimeInterval(3)
    while media.counters().video.shownFrames < wanted, Date() < until { Thread.sleep(forTimeInterval: 0.02) }
    return media.counters().video.shownFrames
}

func decoderCheck(hevc: Bool) {
    let kind = hevc ? "HEVC" : "H.264", frames = 45
    let units = Units()
    let given = con_check_encode(hevc ? 1 : 0, 640, 360, Int32(frames), { bytes, length, parameters, context in
        guard let bytes, let context else { return }
        Unmanaged<Units>.fromOpaque(context).takeUnretainedValue().list.append((Array(UnsafeBufferPointer(start: bytes, count: Int(length))), parameters != 0))
    }, Unmanaged.passUnretained(units).toOpaque())
    let parameters = units.list.filter(\.parameters).flatMap(\.bytes), stream = units.list.filter { !$0.parameters }.map(\.bytes)
    check("\(kind): the device encoder produces a test stream", given > 0 && stream.count == frames && !parameters.isEmpty, "\(stream.count) frames, \(parameters.count) bytes of parameter sets, encoder returned \(given)")
    guard stream.count == frames, !parameters.isEmpty else { return }
    guard let window = con_check_window_open(640, 360) else { check("\(kind): an off-screen window opens", false); return }
    defer { con_video_window(nil); con_check_window_close() }
    con_video_window(window)

    var reader = VideoStream(codec: hevc ? .h265 : .h264)
    let keyframes = stream.indices.filter { index in stream[index].withUnsafeBufferPointer { reader.read($0).isKeyframe } }
    check("\(kind): the shared code finds the keyframes", keyframes.first == 0 && keyframes.count == 2, "\(keyframes)")
    guard keyframes.first == 0, keyframes.count == 2 else { return }
    let second = keyframes[1]
    let asked = Asked()
    var media = AndroidMedia(hevc: hevc)
    media.requestKeyframe = { asked.add() }
    let early = give(media, stream[5])
    check("\(kind): a frame before any keyframe is rejected and a keyframe is requested", !early && asked.times == 1 && media.counters().video.shownFrames == 0, "requested \(asked.times)")
    var taken = feed(media, stream.enumerated().map { keyframes.contains($0.offset) ? parameters + $0.element : $0.element })
    var shown = pictures(media, atLeast: frames)
    let figures = media.counters().video
    check("\(kind): every frame is accepted and drawn", taken == frames && shown >= frames - 2 && con_check_window_pictures() > 0, "\(taken) accepted, \(shown) drawn, \(con_check_window_pictures()) reached the window")
    check("\(kind): the frame size is read from the stream", figures.width == 640 && figures.height == 360, "\(figures.width)x\(figures.height)")
    media.close()

    media = AndroidMedia(hevc: hevc)
    check("\(kind): parameter sets alone are accepted", give(media, parameters))
    taken = feed(media, stream)
    shown = pictures(media, atLeast: frames)
    check("\(kind): a stream with separate parameter sets is drawn", taken == frames && shown >= frames - 2, "\(taken) accepted, \(shown) drawn")

    con_video_window(nil)
    let without = give(media, stream[1])
    con_video_window(window)
    let beforeKeyframe = give(media, stream[2]), atKeyframe = give(media, parameters + stream[second])
    feed(media, stream[(second + 1)...])
    shown = pictures(media, atLeast: frames - second)
    check("\(kind): after a surface change the stream resumes at the next keyframe", !without && !beforeKeyframe && atKeyframe && shown >= frames - second - 2, "\(shown) drawn of \(frames - second)")
    media.close()

    media = AndroidMedia(hevc: hevc)
    _ = give(media, parameters)
    taken = feed(media, stream[..<second])
    shown = pictures(media, atLeast: second)
    check("\(kind): every engine frame is accepted", taken == second && shown >= second - 2, "\(taken) accepted of \(second), \(shown) drawn")
    media.close()

    media = AndroidMedia(hevc: hevc)
    _ = give(media, parameters)
    let hidden = (second / 3)..<(second / 3 + min(9, second / 3))
    taken = feed(media, stream[..<second], display: { !hidden.contains($0) })
    _ = pictures(media, atLeast: second - hidden.count)
    Thread.sleep(forTimeInterval: 0.3)
    let decodeOnly = media.counters().video
    check("\(kind): decode-only frames are accepted but not drawn", taken == second && decodeOnly.hiddenFrames == hidden.count && decodeOnly.decodeFailures == 0
            && decodeOnly.shownFrames <= second - hidden.count && decodeOnly.shownFrames >= second - hidden.count - 2,
          "\(taken) accepted of \(second), \(decodeOnly.hiddenFrames) hidden, \(decodeOnly.shownFrames) drawn of \(second - hidden.count)")
    media.close()

    media = AndroidMedia(hevc: hevc)
    _ = give(media, parameters)
    feed(media, stream[..<second])
    _ = pictures(media, atLeast: second - 2)
    con_video_window(nil)
    let gone = give(media, stream[second - 1])
    con_video_window(window)
    let bare = stream[second].withUnsafeBufferPointer { VideoStream.units(in: $0) }
        .filter { nal in hevc ? !(32...34).contains(Int(nal[nal.startIndex] >> 1) & 0x3F) : !(7...8).contains(Int(nal[nal.startIndex]) & 0x1F) }
        .flatMap { [0, 0, 0, 1] + $0 }
    let waiting = give(media, stream[second - 1]), resumed = give(media, bare)
    feed(media, stream[(second + 1)...])
    shown = pictures(media, atLeast: frames - second)
    check("\(kind): a restarted decoder resumes at the next keyframe", !gone && !waiting && resumed && shown >= frames - second - 2, "\(shown) drawn of \(frames - second)")
    media.close()
}
if con_check_begin() != 0 {
    decoderCheck(hevc: false)
    decoderCheck(hevc: true)
} else {
    check("video decoding can be tested here", false, "this process receives no codec callbacks")
}

do {
    let media = AndroidMedia(hevc: false)
    let silence = [Int16](repeating: 0, count: 480 * 2)
    silence.withUnsafeBufferPointer { media.audio($0, channels: 2, rate: 48_000) }
    Thread.sleep(forTimeInterval: 0.3)
    var opened: Int32 = 0, refusedAtStart: Int32 = 0
    con_audio_counts(&opened, &refusedAtStart)
    let pieces = 50, start = Date()
    for piece in 0..<pieces {
        silence.withUnsafeBufferPointer { media.audio($0, channels: 2, rate: 48_000) }
        let next = start.addingTimeInterval(Double(piece + 1) * 0.01).timeIntervalSinceNow
        if next > 0 { Thread.sleep(forTimeInterval: next) }
    }
    var written: Int32 = 0, refused: Int32 = 0
    con_audio_counts(&written, &refused)
    let paced = Int(written - opened), dropped = Int(refused - refusedAtStart)
    check("audio is written to the system output", opened > 0 && paced >= 480 * pieces * 9 / 10 && dropped <= pieces / 10,
          "\(paced) frames of \(480 * pieces) in real time, \(dropped) buffers dropped; \(opened) at start")
    media.close()
}

print(failures == 0 ? "PASS: the shared code runs on this system" : "FAILED: \(failures) checks")
exit(failures == 0 ? 0 : 1)
