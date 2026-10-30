import CSDL2
import CConDesktop
import Foundation

#if os(Windows)
@_silgen_name("_dispatch_main_queue_callback_4CF") private func drainMainQueue(_ unused: UnsafeMutableRawPointer?)
#endif

if CommandLine.arguments.contains("--check-generation") {
    let result = con_video_generation_check()
    switch result {
    case 0...: logLine("generation: bar at row \(result) (expected about 190)")
    case -1: logLine("generation: unavailable")
    case -2: logLine("generation: no frame produced")
    default: logLine("generation: no bar found")
    }
    exit(result >= 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--check-sound") {
    guard SDL_Init(UInt32(SDL_INIT_AUDIO)) == 0 else { exit(1) }
    for index in 0..<SDL_GetNumAudioDevices(0) {
        var spec = SDL_AudioSpec()
        let name = SDL_GetAudioDeviceName(index, 0).map { String(cString: $0) } ?? "?"
        let channels = SDL_GetAudioDeviceSpec(index, 0, &spec) == 0 ? "\(spec.channels) channels, \(spec.freq) Hz" : "spec unknown"
        logLine("sound: \(name): \(channels)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--check-upscale") {
    var failed = con_video_upscale_check()
    if SDL_Init(UInt32(SDL_INIT_VIDEO)) == 0 {
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "direct3d11")
        if let window = SDL_CreateWindow("Con check", 0, 0, 1280, 720, UInt32(SDL_WINDOW_HIDDEN.rawValue)),
           let renderer = SDL_CreateRenderer(window, -1, UInt32(SDL_RENDERER_ACCELERATED.rawValue)) {
            var info = SDL_RendererInfo()
            SDL_GetRendererInfo(renderer, &info)
            logLine("upscale: SDL renderer \(String(cString: info.name))")
            failed |= con_video_upscale_check_on(renderer)
        } else {
            logLine("upscale: no hidden window: \(String(cString: SDL_GetError()))")
        }
    }
    exit(failed)
}
Program.prepareText()
MainActor.assumeIsolated { Shell.start() }
while true {
    let resting = MainActor.assumeIsolated { Shell.shared?.turn() ?? true }
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: resting ? 0.008 : 0.001))
    #if os(Windows)
    drainMainQueue(nil)
    #endif
}
