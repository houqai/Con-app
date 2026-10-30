# Porting to other systems

How Con is split between shared code and per-system shells, and what a new port needs. The current build is in [docs/BUILD.md](docs/BUILD.md), the Android layer in detail in [docs/ANDROID.md](docs/ANDROID.md), the code structure in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Decision: shared code in Swift

The shared code for all systems is written in one language — Swift, on top of the engine in Rust with a C interface. For each system only its shell is written: windows, picture and sound output, gamepad reading, sign-in storage.

Why Swift: all the logic is written in it and covered by tests; Swift has an official compiler for Windows and an official kit for building for Android; it calls C interfaces directly, and the engine and the platform code expose one. Another shared language (Kotlin Multiplatform, C++, Dart) would mean rewriting the working shared code, including the macOS version.

Which language what is written in: Con's own code is Swift and Rust. The engine (`Engine/`) and the platform code (`Platform/`) are Rust; the shared modules and the shells for macOS, Linux and Windows are Swift; on Android the screens are a small Java layer over the same Swift and Rust core.

What this decision does not give: a shared interface. SwiftUI exists only on Apple systems, so the screens on other systems are written with those systems' own tools and call the shared code.

## Checking a port

| Script | What it checks |
|---|---|
| `Scripts/check-shared-systems.sh` | The four shared Swift modules compile for Linux (aarch64, x86_64) and Android (arm64, x86_64). Run it after changes in the shared modules. |
| `SWIFT_SDK=<name> Scripts/check-shared-sdk.sh` | The same for one Swift SDK. |
| `Scripts/build-shared-android.sh` | Links the shared code with the engine into `libConShared.so`, the library the Android app loads, and checks that every symbol it imports exists in the Swift libraries for Android or in Android itself. |
| `Scripts/test-shared-android.sh` | The shared code tests on a connected Android device. Tests that read project sources are skipped there. |
| `Scripts/check-android-run.sh` | The shared code in one process with the engine on the device (see "Checks on the device" below). |
| `Scripts/run-android-check-app.sh` | Installs and starts the Android app. |

The device scripts take the only connected device; with several, the one named in `ANDROID_SERIAL`. The Linux version is built and run as described in [docs/LINUX.md](docs/LINUX.md), the Windows version in [docs/WINDOWS.md](docs/WINDOWS.md). In the 32-bit Android build the compiler does not see overflows that only happen at run time.

Building for other systems needs the swift.org toolchain of the same version as the Swift SDKs (the Xcode compiler is not suitable), the static Linux Swift SDK, the Android Swift SDK, Android NDK r30 in `work/swift-toolchain/android-ndk-r30` and the Android SDK tools. Paths and versions are in [docs/BUILD.md](docs/BUILD.md). The NDK is distributed under Google's Android SDK licence: it may only be used for developing for Android.

Known gaps: Linux on x86_64 (Steam Deck, ordinary PCs) and on a real Steam Deck; on Android — a real gamepad and Remote Play with a console.

## Layer 1. Engine

- **Stream engine** — `Engine/` (Rust): the Takion protocol, encryption, error correction, video and audio reception, input sending, console discovery, console registration, measurement to the cloud datacenters. One static library per system (`Engine/build.sh <target>` → `work/engine-rust/<target>`), libopus inside, with a C header that `Engine/build.sh` generates in `work/engine-rust/include/con_engine.h`.
- **Con platform code** — `Platform/` (Rust): the list of the computer's networks for console discovery (getifaddrs, on Windows GetAdaptersAddresses), the heap under Wine, Objective-C exceptions. One static library per system (`Platform/build.sh <target>` → `work/platform-rust/<target>`).

## Layer 2. Shared Swift code — taken as is

Four modules know nothing about macOS: they need only Foundation and each other. The `PortabilityTests` test prevents adding a dependency on a single system's library to them. Next to each file there are tests.

| Module | What is in it |
|---|---|
| `SoleCore` | Parsing of PSN and Store responses, the catalog, game history, texts and translation into 11 languages (`Localization`, English texts as keys, tables in `Translations`). Unpacking a compressed server response where the system does not do it (`Gzip`, `plainData`). Parsing of the H.264/H.265 video stream: units, parameter sets for the decoder, which frame is a key frame (`VideoStream`). Frame display rules: the display clock (`PresentationClock`), renumbering HEVC frames after losses (`PictureOrderBridge`), distinguishing a new frame from a repeat (`PictureCadence`), room for generation (`GenerationRoom`), picture counters and the calculation of latency to the screen (`VideoStats`), the path of a decoded picture to the screen — queue, repeats, late frames, generation between frames (`PictureQueue`). Sound: how much to keep in reserve and when to restart output (`SoundQueue`), DualSense vibration as sound (`HapticsSound`). The PS button menu (`StreamMenu`), the on-screen keyboard (`PadKeyboard`), gamepad presses in the library (`LibraryPresses`), the gamepad in the interface: the focus frame and its movement between screen objects, the selection list, text entry (`FocusModel`, `FocusGeometry`). Colour by hue angle for covers without an image (`ColorWheel`). |
| `SoleCloud` | The Sony cloud: session creation (`CloudSession`), licences and library (`CloudEntitlement`, `OwnedLibrary`), server allocation, datacenters, the PS4/PS3 catalog (`PSPlusPC`). |
| `SoleEngine` | Wrapper over the engine's C interface: session, console discovery and registration, measurement to datacenters. Keys as positions on the keyboard, the same on all systems (`Key`). The gamepad as any system reads it (`PadReading`). Keyboard and mouse as a gamepad: layout, mouse as a stick, what is held right now (`KeyboardPlay`). DualSense: report bytes and what to send it and when (`DualSenseDriver`). |
| `SoleLogic` | App behaviour without a screen. The app model (`AppModel`): account, sign-in and sign-out, loading history, licences and catalogs, favourites, settings, launching a cloud game — everything the interface shows and calls. Stream (`StreamModel`): console discovery and registration, connecting and disconnecting, game events, statistics, the PS button menu, stream settings. Library: which games go in which tab, order, "Purchased", "Recent", which catalog game is launched in place of the chosen one (`Library`). The whole order of connecting to the cloud from licence to server (`CloudAuthorization`), the stream description for the engine (`CloudStream`), cloud error texts and whether a retry is possible (`CloudFailure`). PSN sign-in, token refresh, profile and history (`PSNAuthorization`). Stream statistics and total latency (`StreamStats`, `StreamMeter`). The PS button and the menu over the game, touchpad fingers, gamepad orientation (`StreamControls`). Stream states and texts (`StreamSession`). The library screen without the picture (`LibraryScreen`): how many games are shown, where a gamepad or key press moves the selection, "Show more", launching a game over the screen. Controls (`Controls`): key and button names, groups in the settings, mouse settings, what the gamepad asks of the library, the gamepad check. What the screens over the stream show (`StreamPanel`): the line of live numbers, menu lines, genres, generation resolution options. |

What the shared code takes from the system through Foundation: HTTP (`URLSession`), settings (`UserDefaults`), the cache folder for diagnostics. The shared Swift code does not open sockets itself — the engine opens them, and the list of networks comes from the platform code (`Platform/src/net.rs`); the `PortabilityTests` test enforces this.

## Layer 3. System shell — written for each one

On macOS this is `SoleMedia` (video and sound) and the `Sole` app (screens and system services). The shared code expects three things from the shell, described by protocols (the full list of five, with `StreamPlayer` and `StreamMedia`, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#what-the-shell-must-provide-to-the-shared-code)):

- `CredentialStore` — secure sign-in storage: read, write, delete a record by name. On macOS this is `KeychainCredentials`.
- `SonyLoginPage` — the Sony sign-in page in the system's web window: open an address, wait for the response and the cookies. On macOS this is `SonyWebsiteLogin`.
- `StreamDevice` — the system's side in the stream: open picture and sound reception (`StreamMedia`), read the gamepad, keyboard and mouse, pass the gamepad its effects, keep the screen from going dark, store registered consoles. On macOS this is `MacStreamDevice` in `RemotePlay.swift`.

The shell creates `StreamModel` with the device and `AppModel` with the storage, the sign-in page and this stream, shows their properties and calls their functions. Before each change the model calls `willChange` — through it the interface learns that it is time to redraw. On macOS this is done by `SoleModel`, `RemotePlay` and `ControllerFocus`: thin subclasses of the shared models that connect `willChange` to SwiftUI.

The shell provides three more things without a protocol, as ready values:

- **Gamepad reading** — one function "system gamepad → `PadReading`" (buttons, triggers, sticks). From this reading the shared code makes stream input, movement through the library (`libraryActions`) and the gamepad check in the settings (`heldText`). On macOS this is `GCExtendedGamepad.reading` in `Controllers.swift`.
- **Keys** — a table "system key code → `Key`". The shared layout, its storage and key names are known only to `Key`. On macOS this is `MacKeys` in `KeyboardInput.swift`.
- **Library screen** — the shell creates `LibraryScreen` with the app model and the gamepad focus frame, reports how many tiles it has in a row (`columns`), and passes presses (`gamepad`, `key`). The screen objects the focus frame lands on are named with names from `LibraryScreen.Target`.

The rest the shell does itself and passes ready values to the shared code. The equivalents for Android and Windows are a guide, not a fixed choice.

| Service | macOS (file) | Android | Windows |
|---|---|---|---|
| H.264/H.265 decoding | VideoToolbox (`VideoDecoder`, `VideoPipeline`) | MediaCodec | Media Foundation, D3D11 |
| Showing a frame at a given time | AVSampleBufferDisplayLayer (`VideoSurface`) | Surface and Choreographer | Direct3D swap chain |
| Sound | AVAudioEngine (`AudioPlayback`) | AAudio | WASAPI |
| Gamepad: reading into `ControllerState` | GameController (`RemotePlay`, `Controllers`) | InputDevice | GameInput, XInput |
| DualSense: light, triggers, vibration | IOKit HID (`DualSenseOutput`), vibration sound (`DualSenseHaptics`) | USB HID | HID |
| Frame generation | VTLowLatencyFrameInterpolation (`FrameInterpolator`) | none available | none available |
| Sign-in storage (`CredentialStore`) | Keychain (`KeychainCredentials`, `ConsoleStore`) | Keystore | DPAPI |
| Sony sign-in (`SonyLoginPage`) | WKWebView (`SonyWebsiteLogin`) | WebView | WebView2 |
| Keyboard and mouse | AppKit (`KeyboardInput`) | own | own |
| Interface | SwiftUI (`Design`, `Settings`, `GameViews`, `ConsoleViews`, `StreamMenuView`, `PadKeyboardView`) | own | own |

## What is left in the macOS layer

The macOS layer contains only calls to the system; what of them the shell does on another system:

- **Video** (`VideoPipeline`, `VideoDecoder`, `FrameInterpolator`, `VideoSurface`): give the system decoder the units and parameter sets that the shared `VideoStream` extracted, decode a frame and say whether it worked; give the picture to the screen at a given time; compute a picture between two (if the system can). The shared `PictureQueue` takes decoded pictures and itself decides what to show and when.
- **Sound** (`AudioPlayback`, `DualSenseHaptics`): open output, give it a buffer, say when it has been played. When to restart and how much to keep is decided by the shared `SoundQueue`.
- **Gamepad** (`MacStreamDevice` in `RemotePlay.swift`, `DualSenseOutput`, `Controllers`): read buttons and sticks into `PadReading`, the touchpad and sensors into `ControllerState`, find the DualSense and write a report to it. Which reports and when is decided by the shared `DualSenseDriver`.
- **Keyboard and mouse** (`KeyboardInput`): receive events, translate the key code into `Key` and capture the pointer. What is held and where the camera looks is the shared `KeyboardPlay`.
- **Screens** — SwiftUI.

There are no portable rules in the macOS layer. The screens keep only the calculations of the SwiftUI layout itself: how many tiles fit in a row at a given window width and where to scroll a list so that the selected tile is visible.

## Known pitfalls outside macOS

- Keys in the shared code are positions on the keyboard by USB keyboard numbers (`Key`), not the codes of one system. Another system needs its own translation table, like `MacKeys` on macOS: on Windows — from scan codes, on Android — from `KEYCODE_*`. The names of several keys depend on the system (Option or Alt, Return or Enter) and are chosen at build time in `Controls.swift`. A layout saved earlier in macOS codes is translated once on first read (`sole.keyboardLayout` → `sole.keys`).
- Sockets: there are none in the shared Swift code. On Windows the list of the computer's networks comes from `GetAdaptersAddresses` (`Platform/src/net.rs`); it builds under Wine and has not been tested with a real Windows network.
- Engine thread priority: the engine sets the "interactive" class with each system's own means (`con_thread_set_interactive`), the user-initiated class only on Apple systems (`SoleEngine/RustEngine.swift`).
- `Package.swift` in the Android build (`CON_SYSTEM=android`) contains only the shared code, its tests, the Android layer and the check program `Tools/AndroidCheck`; the app and its video and sound are only in the macOS build. Likewise `CON_SYSTEM=linux` and `windows` — their own shells.
- The text about a storage error is written by the shell: the shared code has no word "Keychain".
- Foundation differs between systems. For example, `CGRect` on macOS has no `midX` without an Apple library (on Linux it does), so `FocusGeometry` computes with plain numbers. The portability test does not see such spots — they are caught by the build for another system (`Scripts/check-shared-sdk.sh`).

## Android: what there is and what there is not

Present and working on the device:

- **Engine** (`Engine/build.sh aarch64-linux-android`).
- **Shared code** — the app model, the stream, the cloud, the game library — as one library `libConShared.so` (`Scripts/build-shared-android.sh`) and its tests (`Scripts/test-shared-android.sh`). The app also needs 15 Swift libraries from the Android kit (the build puts all 23 from the kit into the APK) and `libc++_shared.so` from the NDK; the rest is in Android itself starting with version 9 (API 28).
- **Start of the Android layer** — `Sources/SoleAndroid` (built only for Android): `AndroidCertificates.install(in:)` collects the system's root certificates into one file and names it to Foundation. Without this not a single HTTPS request succeeds on Android; call it once at app start.
- **Bridge to Java and Kotlin** — `Sources/SoleAndroid/Bridge.swift` (shared code functions under plain C names) and `Platform/android/src/bridge.rs` (the JNI side in Rust, calls in both directions). Texts go as UTF-8, the app state as JSON. Available through the bridge: start, interface texts, catalog, app model state, sign-in, cancelling sign-in and sign-out, launching a cloud game from the list, cancelling a launch and ending the stream, the surface for the picture, gamepad readings.
- **App model on Android** — `Sources/SoleAndroid/App.swift`: the shared `AppModel` gets from Android what it expects through protocols. Sign-in storage is `AndroidCredentials` on top of `Vault.java` (files in the app folder, encrypted with AES-GCM using a key from Android Keystore). The Sony sign-in page is `AndroidLoginPage` on top of `LoginActivity.java` (WebView; the password is entered on the Sony page, the app waits only for the completion address; cookies and page data are wiped before and after). The stream is played by the shared `StreamModel` (see below).
- **Stream on Android** — the shared `StreamModel` gets from Android the device `AndroidStreamDevice` and the picture and sound receiver `AndroidMedia` (`Sources/SoleAndroid/Stream.swift`). What is in the stream — frame, key frame, parameter sets — is read by the shared `VideoStream`, as on macOS. Decoder and sound — `Platform/android/src/media.rs` (Rust): MediaCodec draws straight onto the stream screen's surface (HEVC for PS5, H.264 for the rest; low-latency mode), AAudio accepts sound without waiting. Before the first key frame and after a loss the picture is not taken, and a key frame is requested from the server, no more often than once every two seconds. If the screen took the surface away and gave a new one, the decoder is reopened and waits for a key frame. The screen is `StreamActivity.java`: a 16:9 surface, a line with launch status and metrics from the shared `StreamPanel`, the gamepad (buttons, D-pad, triggers, sticks — from Android events into the shared `PadReading`), the screen does not go dark while the model asks for it; "back" ends the launch or the stream, and when the app is minimised the stream continues (a service with a notification).
- **The Swift main queue on the Android main thread** — the app model lives on the Swift main actor, while the main thread in an Android app belongs to Android's own loop, and nobody services the Swift queue on it. `con_main_queue_attach` in `Platform/android/src/bridge.rs` asks the Android loop to watch the queue and let it run. The library must be loaded and started on the main thread.
- **Con app for Android** — `Android/CheckApp` (Java, without third-party libraries): screens modelled on the Mac app — library with covers, game page, launch, stream with a panel and a menu, settings, sign-in, consoles (in detail — [docs/ANDROID.md](docs/ANDROID.md)). The screens draw a snapshot of the shared models and pass presses to them; decisions are in the shared code. Built without Gradle using Android SDK tools (`Scripts/build-android-check-app.sh`, APK about 46 MB), installed and launched by `Scripts/run-android-check-app.sh`.

What the Android build requires of the shared code (and what the tests check):

- No sockets in Swift: they are in the engine and in the platform code `Platform/`.
- Foundation outside Apple systems asks the server for a compressed response and gives it to the app unpacked. Every shared code request goes through `plainData`, which unpacks gzip itself (`SoleCore/Gzip.swift`, in pure Swift). On macOS this changes nothing: there the system unpacks it.
- The names of several keys depend on the system (Enter and Return, Alt and Option).
- Foundation outside Apple systems stops the process ("_MultiHandle deallocated with non-zero retain count") if an HTTP session is released while it has an open connection. Every shared code session is created through `URLSession.lasting` (`SoleCore/Sessions.swift`), which outside Apple systems keeps it until the end of the process. The services that create sessions live as long as the app, so nothing extra is kept.
- The same `URLSession.lasting` makes a session without a cookie storage. The Sony authorization request carries the sign-in cookies in its "Cookie" header; Foundation outside Apple systems replaces this header with the cookies the session saved for the address from earlier responses, so the second such request would go out without sign-in and Sony would reply "login_required". On macOS the system does not replace the header.

Missing:

- **A Remote Play check on Android.** The consoles page, registration by code and connecting through the bridge exist, but have not been tested with a real console.
- **The rest of the shell.** Gamepad effects (vibration, triggers, light bar), its sensors and touchpad, keyboard and mouse, frame generation, HDR, a build for the store. Without a gamepad people play with the on-screen gamepad (`TouchGamepad`).

Checks on the device:

| Script | What it checks |
|---|---|
| `Scripts/test-shared-android.sh` | The shared code tests. |
| `Scripts/check-android-run.sh` | The shared code in one process with the engine: settings, certificates, requests to Sony without sign-in. Stream picture and sound — without a stream and without a screen: the Android encoder makes a stream (H.264 and HEVC), `AndroidMedia` decodes it into a window nobody sees, a fifth of a second of silence goes to the sound output. |
| `Scripts/run-android-check-app.sh` | The app installs, starts, reads the catalog. |
| `Scripts/check-android-stream.sh` | One live run of a cloud game on the account signed in on the device: the stream came up, holds, frames are drawn, sound is written. It does not run with the screen off or locked, nor earlier than a minute after the previous session requested from Sony. |

## Numbers: what carries over, what to measure again

- **Carry over** (properties of Sony's servers and the protocol): the reported loss limit of 4 % for PS5 and 2 % for PS4/PS3 with a ×3 margin; waiting 3 ms for a missing packet in the cloud; the ping substitution for Sony; the licence selection rules; the resolution limits of the PS4 (1080p) and PS3 (720p) clouds.
- **Measure again** (properties of macOS and the Mac's display): the 21 ms display lead and the formula of latency to the screen in `VideoStats` — they come from AVSampleBufferDisplayLayer; the limits and timing of frame generation; the time it takes to hand a frame to the window server.

## Rule for new code

A new behaviour rule is written in a shared module and with a test; only the call to the system remains in the shell. The shared code must not link libraries of a single system: if it needs a system service, it describes it with a protocol, and the shell provides it.
