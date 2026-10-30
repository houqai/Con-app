# The Android layer

What exists on Android today: the shared code and the engine as one library, a bridge to Java, the decoder and sound, and **the Con app for Android** with screens modeled on the Mac app: a library with cover art, the game page, launch, the stream with its panel and menu, settings, sign-in, consoles. It grew out of the check app and kept its package (`app.con.check`) and folder (`Android/CheckApp`), so that an update does not reset the sign-in on the phone. It is not a product yet: there is no store build, and it has been tested on one phone. The overall picture of the port is in [Porting.md](../Porting.md); the build is in [BUILD.md](BUILD.md).

Tested on a Pixel 10 Pro (Android 17, arm64). The minimum Android version is 9 (API 28).

## What it is made of

```
Android/CheckApp (Java)                      screens modeled on the Mac, WebView, Keystore, gamepad
        │  JNI
Platform/android (Rust, crate con-android; for Swift, the module CConAndroid)
   bridge.rs   JNI (crate jni): calls in both directions, the Swift main queue on the Android main loop
   media.rs    MediaCodec → screen surface; AAudio (crate ndk-sys)
        │
Sources/SoleAndroid (Swift)
   Bridge.swift        shared-code functions under C names (con_…)
   App.swift           AppModel, LibraryScreen, FocusModel on Android; storage, sign-in page, gamepad
   Screens.swift       what the screens see (state snapshot) and what they can ask for (act)
   Stream.swift        AndroidMedia, AndroidStreamDevice
   Certificates.swift  root certificates for HTTPS
        │
SoleLogic · SoleCloud · SoleEngine · SoleCore      shared code, the same as on macOS
        │
engine (Engine/, Rust), built for Android
```

Everything except Java is linked into one library, `libConShared.so` (`work/android/<abi>/`). The engine is `work/engine-rust/<arch>-linux-android/libcon_engine.a` (`Engine/build.sh aarch64-linux-android`, see [ARCHITECTURE.md](ARCHITECTURE.md), "Engine"), with libopus inside it; Con's platform code is `work/platform-rust/<arch>-linux-android/libcon_platform.a` and the Android side `libcon_android.a` (`Platform/build.sh aarch64-linux-android`; the header `con_android.h` is made by cbindgen). The check program `ConAndroidCheck` also links `libcon_android_check.a` (`Platform/android-check`: an off-screen window and a test stream from the device's encoder); none of this goes into the app. `check-android-library.py` checks that the library exports `JNI_OnLoad` and all the native methods of `Shared.java`. The app also carries the Swift libraries from the Android SDK bundle and `libc++_shared.so` from the NDK.

## How Java and the shared code talk

Texts travel as UTF-8, state as a single JSON string. Java knows no Swift types and makes no decisions: what to show, what a tap does, where the focus frame goes is decided by the shared models (`AppModel`, `LibraryScreen`, `FocusModel`, `StreamModel`), as on the Mac.

### Java → shared code (`Shared.java`, natives)

| Method | What it does |
|---|---|
| `start(files, caches)` | Once, on the main thread: app folders, certificates, engine, model. Returns the number of root certificates. |
| `state()` | A snapshot of everything the screens show (JSON, see below). |
| `act(name, value)` | A screen's request to the model, by name: catalog (`destination`, `backend`, `filter`, `search`, `columns`, `more`, `reload`), game (`open`, `closePage`, `favorite`, `play`, `cancelLaunch`, `retry`), settings (`settings`, `closeSettings`, `section`, `select`, `choice`, `headerMenu`, `preset`, `bitrate`, `haptics`), sign-in (`loginOpen`, `signIn`, `cancelSignIn`, `signOut`, `message`), gamepad (`press`, `targets`), stream (`stats`, `openMenu`, `menuChoose`, `menuClose`, `leave`), consoles (`register`, `connectConsole`, `removeConsole`, `clearFailure`, `loginPin`), first launch (`deviceLanguage`). Parsed by `AndroidApp.act` in `Screens.swift`. |
| `ask(name, value)` | A question that Sony answers (not for the main thread). There is one now: `screenshots`, the game's screenshots. |
| `text(english, language)` | An interface text in a language, looked up by its English text. |
| `loginFinished(address, sentSecurely, sentPlainly)` | The sign-in page reached the return address; with it, the cookies the web component would send to the account site over HTTPS and without it. |
| `loginClosed()` | The sign-in page was closed. |
| `surface(Surface)` | The surface for the picture; `null` takes it away before it is destroyed. |
| `pad(buttons, l2, r2, lx, ly, rx, ry)`, `padGone()` | Gamepad readings; the gamepad went away or the screen lost focus. During a stream they go to the game, outside it to the library: 20 times a second, with the held direction repeating (`LibraryPresses`), as on the Mac. |
| `storeCheck()` | A storage check with a record that holds no secret. |

The bits of `buttons`, from the lowest: ✕ ○ □ △ L1 R1 L3 R3 Options Create PS touchpad ↑ ↓ ← →. Triggers 0…1, sticks −1…1, up is plus.

### Shared code → Java (static methods of `Shared`, called from any thread)

| Method | What it does |
|---|---|
| `storeRead`, `storeWrite`, `storeRemove` | Protected storage (`Vault`). |
| `openLogin(address, scheme)`, `closeLogin()` | Open and close the Sony sign-in page. |
| `changed()` | The model state changed: the screens re-read the snapshot. |
| `keepAwake(on)` | The stream asks for the screen to stay on. |
| `activate(target)` | The gamepad pressed ✕ on a screen object: the screen presses it, like a tap. |

`JNI_OnLoad` looks these methods up in advance and refuses to load the library if any one is missing: a mismatch between Java and Rust shows at once, not in the middle of work.

### State snapshot

Built in `AndroidApp.picture()` (`Screens.swift`). The main parts:

| Fields | Meaning |
|---|---|
| `account`, `avatar`, `restoring`, `signingIn`, `signingOut`, `authError`, `loginOpen`, `message` | Account, sign-in, message. |
| `destination`, `backend`, `filter`, `filters`, `search`, `countText`, `tiles`, `more`, `empty`, `error`, `glow` | Library: what is selected; tiles of the rows shown (cover, title, favorite, color when there is no cover); background colors from the selected game. |
| `gameOpen`, `page` | Game page: the caption above the title, the store, the background color. |
| `launching`, `connecting`, `launchGame`, `cloudStatus`, `cloudError`, `canRetry` | Launching a cloud game. |
| `phase`, `streamStatus`, `statsVisible`, `cells`, `menu`, `panel` | Stream: phase, stats line cells at three levels of detail, the PS button menu. |
| `settings` | Section, selected list values, quality, bitrate, datacenter, labels. |
| `consoles` | Consoles found, saved consoles, status, code request. |
| `focus`, `choices`, `choiceIndex`, `held` | Focus frame, choice list, what is held down on the gamepad. |
| `t` | The screens' words in the app language (through `loc`, with translations). |
| `listed`, `listedIDs`, `listedCount`, `catalogue`, `history`, `drawn`, `size`, `sound`, `soundLeftOut` | For the check scripts. |

## What Android needed in particular

- **Root certificates.** Foundation on Android does not find them by itself: `AndroidCertificates.install` gathers the system certificates into one file and tells Foundation its name. Without this no HTTPS request goes through. Called in `start`.
- **The Swift main queue.** The model lives on the main actor, and in an Android app the main thread belongs to the Android loop. `con_main_queue_attach` asks that loop to service the Swift queue. That is why the library is loaded and started on the main thread.
- **Sign-in cookies.** WebView reports only a cookie's name and value. A cookie counts as secure if WebView would send it over HTTPS and would not send it without HTTPS (`SonySSO.credential(sentSecurely:sentPlainly:)`).
- **Compressed responses, sessions and cookies in Foundation**: three differences from Apple's systems, solved in the shared code; see [DEVELOPMENT.md](DEVELOPMENT.md).

## Screens

Drawn in Java code, with no layout files and no third-party libraries, modeled after `Sources/Sole` (SwiftUI): the same colors, sizes in Mac points (dp on Android), the same width thresholds for a narrow window. There are no SF Symbols on Android, so the icons needed are drawn with lines (`Look.Icon`).

- `MainActivity`: the app window: the header (logo, search, menu or tabs, account), the catalog (PS5 / PS4 / PS3, filters, a grid of covers with a favorite star, "Show more"), the game page (blurred cover as background, "Play", favorite, store, screenshots), "My consoles", sign-in, the choice list, messages, the focus frame. On a phone in portrait orientation the game page puts the cover above the title; on the Mac they are side by side.
- `SettingsPanel`: settings: "General", "PSN Account" (with trophies and recent games), "Stream", "Controls", "About Con". All tabs are visible: what does not fit on a line wraps to the next one (the same as on the Mac in a narrow window). Settings that do not apply on a phone are left out: smooth presentation, frame generation, keyboard and mouse.
- `ConsolesPage`: consoles on the network, registration by code, saved consoles.
- `StreamActivity`: launch (game cover, progress, error, "Cancel" / "Close") and the stream: a 16:9 picture or full screen (the "Picture size" setting); a control panel on tap that goes away after 3 seconds: "Disconnect", stream stats, menu; the stats line; the PS button menu. The menu also opens with a button on the panel, since a phone may have no gamepad. The menu has no "Full screen" item on a phone (`StreamDevice.leavesFullScreen`). A swipe from the edge first shows the system bars, and "back" works on the second one. "Back" ends the launch or the stream. If the app is minimized, the stream goes on: the picture is not decoded while the screen is not visible (on return, from the next keyframe), and the sound plays. It is kept alive by `StreamService`, a foreground service with a notification: tapping the notification returns to the stream, and its "Disconnect" button ends it; closing the app from the recents list ends it too. Permission for notifications is asked once, at the first game launch.
- `TouchPadView`: an on-screen gamepad over the stream when a real one is not connected (the "On-screen gamepad" setting in "Controls" and a button on the stream panel): the d-pad and left stick on the left, ✕○□△ and the right stick on the right, L1/L2 and R1/R2 in the top corners, Create, PS, Options and the touchpad at the bottom in the middle; touching a stick without moving it is L3/R3. The layout and what the fingers hold is decided by the shared `TouchGamepad` (SoleLogic, with tests); the screen draws it and passes the touches on (`con_touch`). Presses from the on-screen and the real gamepad add up. While the on-screen gamepad is visible, the stream panel sits at the top in the middle.
- `LoginActivity`: the Sony sign-in page in a WebView. The password is entered on Sony's page; cookies and page data are wiped before it opens and after it closes; only HTTPS addresses are followed.
- `Vault`: records are encrypted with AES-GCM using a key from the Android Keystore (the key cannot be extracted) and are stored as files in the app folder.
- `Images`: covers and Store screenshots (public images only, over HTTPS), scaled down to display size, shared by the catalog and the game page.
- `Pad`: gamepad reading, shared by both screens.

The app is built without Gradle, with the Android SDK tools (`Scripts/build-android-check-app.sh`); the icon and logo are `Resources/Con.png`, and `THIRD-PARTY-NOTICES.md` ("Licenses") is put into the app.

## Stream

`AndroidMedia` receives stream blocks from the engine. The shared `VideoStream` says whether a block holds a frame and whether it is a keyframe. Then `media.rs` (Platform/android):

- the decoder opens at the first block, when the screen has a surface; HEVC for PS5, H.264 for the rest; low-latency mode;
- what goes into the decoder is decided by the shared `LossGate` (SoleCore): the Android decoder does not refuse a frame built on a lost picture, it draws it broken up instead. The engine itself keeps track of the decoder's pictures, repairs a frame after a loss or does not hand it over, so `LossGate` lets everything into the decoder; a keyframe is waited for only after the decoder itself refuses (a frame is not taken) and after it restarts, and a restarted decoder gets the stream parameters (VPS/SPS/PPS) in one block with the keyframe if the frame does not carry them; the engine sends them once, before the first frame. "Held" in the stats line counts only such frames. A keyframe is requested no more often than once every two seconds;
- after a loss the engine repairs the frame references and marks frames with wrong content "decode only": they go into the decoder as usual (the following frames rely on them), and the output buffer of such a frame is released without being shown (`delay_us` = −1 → `releaseOutputBuffer(index, false)`); the screen keeps the last correct picture until the server's recovery frame (about 150 ms). They do not upset the presentation rhythm (`PresentationClock` takes them as a repeat), and they are not counted as lost or "held"; the stats line shows "hidden N in M runs" (the engine's counters);
- when to show a frame is decided by the shared `PresentationClock` (an even grid with a lead, the "Smooth presentation" setting, on by default); a separate thread takes decoded frames and hands them to the screen for that time (`releaseOutputBufferAtTime`), so the engine thread does not wait for the decoder;
- decode time is measured from feeding a frame to its leaving the decoder, and is shown in the stats line;
- if the screen took the surface away, the decoder closes; with a new surface it opens again and waits for a keyframe (with the stream parameters, see above);
- sound is written to AAudio without waiting, along the normal (not low-latency) path with a margin of about 1/7 second: what does not fit is skipped, which is less audible than lagging behind the picture. The loudness of every chunk is measured (the "heard" and "peak" counters in the check log).

Tested with a PS5 cloud game (Cyberpunk 2077, Tokyo server): 1920×1080, H.265, about 60 frames per second, 8 Mbps, with sound.

## Checks

The table of scripts is in [BUILD.md](BUILD.md#android). The scripts read only log records with the app's tag (`ConCheck`) and system properties; they take screenshots only with `SHOT=1`; test files go to `/data/local/tmp` and are removed afterwards.

`check-android-stream.sh` starts a game with an app launch parameter and a request number, only through the entry point `app.con.check/.CheckPlay`, which is guarded by the permission `android.permission.DUMP` (`adb shell` has it, other apps on the phone do not, so they cannot start a game through Con): for one number the game starts once, however many times the app is opened afterwards (Android keeps the launch parameters with the app's entry in the recents list).

## What is missing

- A test of the on-screen gamepad in a real game, and a test with a real gamepad: reading the buttons, d-pad, triggers and sticks and moving the focus frame across the screens are written from the Android documentation.
- Gamepad effects (vibration, triggers, light bar), its sensors and touchpad; keyboard and mouse.
- Frame generation.
- HDR.
- An on-screen keyboard for searching with a gamepad (on the Mac, `PadKeyboard`): search opens the system keyboard.
- A store build and signing for distribution.
