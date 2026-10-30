# Windows version

Con for Windows is the same app as on Linux: the shared code (`SoleCore`, `SoleCloud`, `SoleEngine`, `SoleLogic`), the engine (`Engine/`, Rust; see [ARCHITECTURE.md](ARCHITECTURE.md), "Engine") and the shell shared with Linux (`Sources/ConDesktop`: SDL 2 window, screens on Cairo/Pango, FFmpeg). It is built entirely on a Mac, without Windows. The target is Windows 10 and 11, x64.

It builds on the Mac. On Windows 11 x64, sign-in, cloud streaming at 1440p60, and gamepad and keyboard input work; the shared code tests pass under Wine (CrossOver on the Mac). What is missing or untested is listed at the end.

## What it is made of

```
con-app.exe (Sources/ConDesktop, Swift)   window, screens, input; shared with Linux (there the program is "con")
Platform/desktop (Rust, con_desktop.lib)   Credential Manager, FFmpeg (Store pictures and the stream), SDL texture; module CConDesktop
con-login.exe (Platform/login, Rust)       Sony sign-in window: WebView2 (webview2-com, loader built in), InPrivate
Platform/ (Rust, con_platform.lib)         networks for finding consoles; under Wine, memory for Swift above 2 GB (see below)
```

| What | With what on Windows |
|---|---|
| Screens | SDL 2 + Cairo/Pango, as on Linux; text is Pango through fontconfig and FreeType, the Inter font ships with Con (`fonts/`) |
| Stream picture | FFmpeg: the graphics card (D3D11VA), without it the processor → SDL texture; frame generation through AMD AMF FRC (`Platform/desktop/src/frc.rs`); what to feed it is decided by `LossGate` (everything except frames after a decoder failure); "decode only" frames are decoded and not drawn |
| Sound, gamepad, keyboard | SDL 2 (DualSense: the full effects report; another gamepad: the motors) |
| Sign-in | `con-login.exe`: Sony's page in WebView2 (the Edge browser, part of Windows 10/11), InPrivate mode; returns the return address and cookies, as on Linux |
| Sign-in storage | Windows Credential Manager (`app.sole.credentials/<name>`) |
| Settings | file `%APPDATA%\app.sole.desktop\con-app.plist` (`FileDefaults` in SoleCore) |
| Cache | `%LOCALAPPDATA%\app.sole.desktop\Caches` |

## The name "con"

Windows reserves the name `CON` for the console, for a file or folder with any extension. Therefore: the program is called `con-app.exe`, the logo `con-logo.png`, the settings folders `app.sole.desktop`, the finished folder `Con-windows-x64`. **Do not put Con in a folder named `Con`**: in such a folder Foundation stops the program.

## Building (on a Mac)

Needed: the swift.org 6.4 compiler (`~/Library/Developer/Toolchains/swift-latest.xctoolchain`), Rust, Homebrew `cmake ninja llvm msitools sevenzip`, `cargo install xwin`.

```sh
Scripts/windows-sdk.sh            # Windows SDK and Microsoft C library (xwin) + Swift libraries for Windows → Swift SDK
Scripts/windows-deps.sh           # SDL 2, FFmpeg, Cairo/Pango (gvsbuild), WebView2 SDK license, Inter font, by checksums
Engine/build.sh x86_64-pc-windows-msvc   # engine → work/engine-rust/x86_64-pc-windows-msvc/con_engine.lib
Platform/build.sh x86_64-pc-windows-msvc # platform code, con_desktop.lib and con-login.exe → work/platform-rust/x86_64-pc-windows-msvc/
Scripts/build-windows.sh          # → work/windows/Con-windows-x64 (release; debug as an argument; zip with "release zip")
Scripts/test-shared-windows.sh    # shared code tests under Wine (XCTest and Swift Testing)
```

`build-windows.sh` and `test-shared-windows.sh` link the engine from `work/engine-rust/x86_64-pc-windows-msvc` (`CON_ENGINE_LIB`) and the platform code from `work/platform-rust/x86_64-pc-windows-msvc` (`CON_PLATFORM_LIB`; without the libraries they stop) with the system libraries from `native-libs.txt` (bcrypt, advapi32, kernel32, ntdll, userenv, ws2_32, dbghelp). The list of networks for finding consoles (`Platform/src/net.rs`) comes from `GetAdaptersAddresses` (iphlpapi; windows-sys links it itself).

`Scripts/windows-sdk.sh` downloads the Windows SDK with xwin, which requires accepting Microsoft's license.

How it works:

- `Scripts/windows-sdk.sh` puts a Swift SDK for SwiftPM into `work/windows/sdks/con-windows.artifactbundle`. Two fixes to Microsoft's headers: in SDK 10.0.26100 the math functions moved from `corecrt_math.h` to `math.h` (the Swift libraries expect the old place), and `threads.h` of the new C library uses two macros this SDK does not know.
- SwiftPM: only `--build-system native`; `pkg-config` gets its descriptions from `work/windows/deps/pkgconfig`, otherwise it would pick up the Homebrew headers of the Mac.
- `Scripts/windows-deps.sh` takes from the gvsbuild archive only the DLLs Cairo and Pango need, and the license of each (`share/doc/<project>` or `share/licenses/<project>`), into `licenses/gtk/<project>` of the program folder; if a DLL has no license, the script stops. A download goes into `<name>.part` and gets its real name only when complete, so an interrupted one is not taken for an archive; an archive with a different checksum is renamed to `<name>.bad`, and the next run downloads it again.
- The engine is `Engine/build.sh`: Rust for `x86_64-pc-windows-msvc`, libopus inside built with clang from swift.org with the Windows SDK from xwin.
- The platform code is `Platform/build.sh`: Rust for `x86_64-pc-windows-msvc` (windows-sys), no C; only the rustup target is needed. After `windows-sdk.sh` and `windows-deps.sh` it also builds the shell parts: `con_desktop.lib` (the FFmpeg interface is generated by bindgen from the `work/windows/deps` headers with the Windows SDK headers; libclang comes from the swift.org compiler) and `con-login.exe` (crates webview2-com and windows; linked by `lld-link` with the xwin libraries; the WebView2 loader is static, from webview2-com-sys, so without WebView2 the program starts and ends with code 3; the icon comes from `Scripts/windows-icon.sh`). `build-windows.sh` puts `con-login.exe` next to `con-app.exe`.

## Checking under Wine (CrossOver)

Tests run in a dedicated `con-test` bottle (Windows 10, 64-bit).

```sh
W=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine
$W --bottle con-test --wait-children "$PWD/work/windows/Con-windows-x64/con-app.exe" --snapshot 'Z:\…\snap.png' 15
```

`--snapshot <file> [seconds]` writes the screens (without the stream picture) to PNG and closes the program: a check without Mac screenshots. The log (stderr) has the same `state:` / `stream:` lines as on Linux; `--play "<part of the title>"` is there too.

### What had to be done for Wine

Swift 6.4 stores in a string either a pointer to its "breadcrumbs" (where the UTF-16 offsets are kept) or, for short text, the UTF-16 length itself, and distinguishes them by value: up to `Int32.max` it is a length. On Windows the heap lies above 4 GB, but Wine on the Mac puts it in the lower 2 GB: the pointer is read as a length, and any work with UTF-16 offsets in non-Latin text breaks (searching in a string stops the program, lengths come out in the millions). `Platform/src/wine.rs`, only under Wine (it detects it by `wine_get_version` in ntdll), redirects `malloc`/`free` and related functions of the program's modules to a separate heap in memory reserved at the top of the address space; a block not from there is returned to the C library as before. It runs before `main` and before Swift code: it is a C runtime initializer (section `.CRT$XCT`), kept in every program by `/include:con_wine_heap_start` (`Package.swift`). On Windows this code does nothing. It is checked by `WineHeapTests` (the heap is on only under Wine, small blocks above 2 GB, UTF-16 offsets and searching in non-Latin text).

Also under Wine: Foundation's standard settings storage crashes when reading (Wine reports the size of the profiles folder differently from Windows), so on Windows the settings are in their own file (`FileDefaults`); fonts of Pango's Windows backend are drawn with clipped letters, so Pango goes through fontconfig, as on Linux.

## What had to be done for Windows

- A program opened from Explorer has no stderr, and Foundation's non-throwing `FileHandle.write(_:)` stops the program on failure (`_assertionFailure` in `swiftCore.dll`, 0xc000001d). Log lines are therefore written with `try? write(contentsOf:)`; `PortabilityTests` checks this.
- The sign-in cookies are larger than a Windows pipe buffer, so Con reads `con-login`'s output as it arrives.
- `con-app.exe` and `con-login.exe` are built as windowed programs (GUI subsystem: `Scripts/build-windows.sh`, `Platform/login/src/main.rs`).

## Status

Tested on Windows 11 x64 (build 26340; Radeon 880M and RTX 5070 Ti Laptop):

- Sign-in through `con-login.exe` (WebView2).
- A PS5 cloud stream (Cyberpunk 2077) at 2560×1440 H.265, 60 fps, with sound; gamepad and keyboard input in the game.
- Decoding on the graphics card (D3D11VA, `Platform/desktop/src/video.rs`) and "Frame generation" through AMD AMF FRC (`Platform/desktop/src/frc.rs`, checked with `con-app --check-generation`); "Smooth presentation" works as on the Mac.
- `con-app.exe` started by double-click opens and loads the catalog and covers.

Tested under Wine:

- The shared code tests (XCTest and Swift Testing) pass; the tests that read the project's sources are skipped, as Mac paths do not exist under Windows. They include the engine tests with the real library (version and header, measurement on loopback, console and cloud sessions on loopback, discovery, console registration, receive thread priority) and `WineHeapTests`.
- `con-app.exe --snapshot`: the window opens, the catalog, logo and covers load, screens in Russian and English; settings are written to `%APPDATA%\app.sole.desktop`.
- `con-login.exe` without WebView2 prints "WebView2 is not there (0x80070002)" and exits with code 3, and Con shows what to install; wrong arguments: code 2.

## What is missing / not checked

- **Installer and signing**: there is a folder and a zip; the programs are not signed (Windows SmartScreen will warn).
- **Size** ~200 MB: of which ~90 MB is a full FFmpeg build (our own minimal one, as in Flatpak, is not done yet).
- **Remote Play with a console**: the shell has it (discovery, registration, "Play"), not checked on Windows.
- **On-screen keyboard** for searching with a gamepad (on the Mac, `PadKeyboard`) is missing.
- **Rumble and DualSense effects** on Windows are not checked.
- **Frame generation**: only on an AMD card (NVIDIA is not used), only with decoding on the graphics card, on a display of 100 Hz or more. Not confirmed: smoothness and artifacts in fast motion, games running at 30 fps.
- **The graphics card for D3D11VA** on a laptop with two cards is the first one in the system; there is no choice.
- Not confirmed: long sessions without drops (`ERROR_IO_PENDING`), the "Smooth presentation" levels (smoothness, delay), launching by double-click without a console window flashing, the window (edges, dragging, full screen).
- **Windows 10** has not been checked (only Windows 11 build 26340, x64).
- **Sign-in under Wine** does not work: WebView2 154 in the `con-test` bottle starts but draws nothing (not helped by `--no-sandbox`, `--disable-gpu`, `--disable-gpu-compositing`, `--disable-direct-composition`). Sign-in is checked only on real Windows; `con-login.exe` writes "page ready" / "page loaded" / "page failed (code)" to stderr, without addresses.
