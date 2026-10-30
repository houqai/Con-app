# How to develop

The rules the code is written by, and known pitfalls. How the code is laid out is in [ARCHITECTURE.md](ARCHITECTURE.md), the commands are in [BUILD.md](BUILD.md).

## Where to put new code

There is one question: **is this a decision about behavior, or a conversation with the system?**

- A decision (what to show, in what order to request, how to interpret a response, what to tell the player, when to ask for a keyframe) goes into a shared module (`SoleCore`, `SoleCloud`, `SoleEngine`, `SoleLogic`) with a test.
- A conversation with the system (draw, decode, read a gamepad, put something into secure storage) goes into the system layer (`Sole`/`SoleMedia` for macOS, `SoleAndroid`/`CConAndroid` for Android), behind a protocol from the shared code.

If an `if` about behavior appears in a system-layer file, it belongs in the shared code.

## Rules the tests enforce

`Tests/SoleCoreTests/PortabilityTests.swift` reads the sources and will not let through:

| Rule | Why |
|---|---|
| Shared modules import only Foundation, `FoundationNetworking` (under `#if canImport`), each other, the engine's C interface (`CConEngine`) and that of Con's platform code (`CConPlatform`). | Otherwise the code will not build outside Apple systems. |
| Names that exist only on Apple are wrapped in `#if`. | The same. |
| Shared Swift has no sockets and no import of the system C library. | Each system has its own sockets; the engine opens them, and Con's platform code provides the list of the computer's networks (`Platform/src/net.rs`). |
| Our own code is Swift and Rust only. | What is needed from the system and cannot be said in Swift goes into `Platform/` (Rust); C remains only in the places listed in `testConsOwnCodeIsSwiftAndRust`, and is not added there. |
| Every HTTP request goes through `plainData`. | Foundation outside Apple systems hands over a gzip response uncompressed. |
| Every HTTP session is created through `URLSession.lasting`. | Foundation outside Apple systems stops the process when a session with an open connection is released, and replaces the request's Cookie header with stored cookies. |
| The listed logic files live in shared modules. | So that logic does not creep back into the interface. |

The shared modules' tests must also pass on Android. Hence two more rules for the tests themselves:

- **Do not guess timing.** A test waits for an event, not for "100 ms should be enough": on a phone it will not be.
- **Wrap what exists only on Apple** (`CryptoKit`, `Network`, `simd`) in `#if canImport`, and skip tests that read the project's sources when the sources are not nearby.

## Texts and translations

- In code, texts are written **in English**: `loc("Creating the game session…")`. The English text is the key.
- Russian lives in `Sources/SoleCore/Translations/RussianTexts.swift`, like the other languages.
- Nine more languages are in `Sources/SoleCore/Translations/<Language>Texts.swift`. A text without a translation is shown in English.
- The tables are not edited by hand: the English texts are in `Tools/Translations/texts.json`, the translations, Russian included, in `Tools/Translations/tr-<code>.txt` (a line `number|translation`, where the number is the text's position in `texts.json`), and the tables are written by `Tools/Translations/make-tables.py <code> …`. It writes nothing if a translation file does not match `texts.json`, and checks that the number of value placeholders (`%@`) and line breaks is the same as in the English.
- The translations into those nine languages are machine translations, not proofread by native speakers.
- The app language and the game language are separate settings with one list (`AppLanguage`, `GameLanguage`).

To check a language without changing the saved setting: launch arguments `-sole.language de` and `-sole.gameLanguage de`.

## Secrets

- The password is entered only on Sony's page. The app does not see it, and the code must not try to.
- The refresh token, sign-in cookies and console keys live only in the system's secure storage. Not in settings, not in files, not in the log.
- The log and diagnostics record the structure of an error, numeric codes and fixed categories. Not Sony response bodies, not headers, not tokens.
- The cloud slot's keys live only in memory.
- The sign-in storage component on macOS (`CredentialAgent/main.swift`) is not changed without migrating the entries: access to the Keychain depends on its bytes.

## Working on the engine

The engine is `Engine/` (Rust), our own, written from the protocol description (`docs/protocol`) by the clean-room method: no other implementation's code is used in it or read while writing it (`docs/protocol/README.md`). The C interface is the header `work/engine-rust/include/con_engine.h`, written by `Engine/build.sh` from the Rust code (cbindgen); Swift talks to it only in `SoleEngine` (`RustEngine.swift` and the wrappers `Discovery`, `Registration`, `Session`, `CloudNetworkProbe`).

1. Edit `Engine/src/...`; tests: `cd Engine && cargo test`.
2. `Engine/build.sh <target>` for each system (targets: [BUILD.md](BUILD.md#engine)).
3. If the header changed, raise `CON_ENGINE_ABI_VERSION`; the test `theLibraryWasBuiltForTheHeaderConUses` will not let an old library be linked with a new header.

## Working on the platform code

`Platform/` (Rust, crate `con-platform`) is what the shared code and the shells take from the system in the system's own language: the computer's networks, the heap under Wine, Objective-C exceptions, a port for tests. Its C interface is generated by cbindgen from `Platform/src` (`Platform/cbindgen.toml`); the header is not written by hand. The same cargo workspace holds the parts of the Linux and Windows shell: `Platform/desktop` (crate `con-desktop`, C interface `con_desktop.h`, module `CConDesktop`) and `Platform/login` (program `con-login`); and the Android layer: `Platform/android` (crate `con-android`, `con_android.h`, module `CConAndroid`) and `Platform/android-check` (`con_android_check.h`, module `CConAndroidCheck`, only for the check program).

1. Edit `Platform/src/...`; tests: `cd Platform && cargo test` (on the Mac), `cargo clippy --target <target>` for other systems.
2. `Platform/build.sh <target>` for each system, with the same Rust as the engine (the script checks).
3. A new function for Swift is `#[no_mangle] pub extern "C"`, on every system (where there is nothing to do, it does nothing), with a test in Rust and, if Swift calls it, in `Tests/`.

Do not copy code under licenses incompatible with the project's GPL-3.0.

## Live runs

Tests do not replace a run against Sony's real server: everything to do with sign-in, licenses, sessions and the stream is ultimately checked by playing.

- Wait about a minute between game launches, counted from the moment a session was actually requested from Sony: Sony keeps the previous session for a while. The response "the account already has a cloud session running" means "too early", not a bug. If Con's own previous stream ended less than 3 minutes ago, Con ends that session itself (`forceLogout`); otherwise it waits and retries the launch, so it never ends a session on another device of the same account.
- Do not replace `Con.app` while it is running. A test build is built in a separate folder, launched hidden and closed by its own path.
- Remove temporary measurement code before committing.

## Known pitfalls

### Foundation outside Apple systems (Android, Linux)

| What happens | What you see | How it was solved |
|---|---|---|
| A response with `Content-Encoding: gzip` is handed to the app compressed. | The JSON does not parse. | `plainData` and our own decompression (`SoleCore/Gzip.swift`). |
| A session with its own cookie storage replaces the request's Cookie header with stored cookies. | The second authorization at Sony goes out without the sign-in cookies: "login_required". | `URLSession.lasting` makes sessions without cookie storage. |
| Releasing a session with an open connection stops the process. | "_MultiHandle deallocated with non-zero retain count", Aborted. | `URLSession.lasting` keeps sessions until the process ends. |
| The system's root certificates are not found (Android). | Not a single HTTPS request goes through. | `AndroidCertificates.install` at startup. |

### Android

- Nobody services Swift's main queue on the main thread until it is attached to the Android loop (`con_main_queue_attach`); the library is loaded and started on the main thread.
- A process started through `adb shell` gets no codec responses until it starts threads for system messages (`con_check_begin` in the check tool). The app does not need this.
- Launch parameters (`am start --es …`) stay with the app's entry among recent apps: a one-time action driven by a parameter has to be made one-time explicitly (a request number).
- `adb logcat -s Tag:I Tag:E` drops Info-level lines; the form `-s Tag:I OtherTag:E` is needed.
- In the emulator Sony's sign-in page refuses (HTTP 429 on its own token request); on a real phone sign-in works. Masking the device or browser to get around Sony's checks is not allowed.

### macOS

- Homebrew libraries are built for the current macOS and may ask the system for what an older one lacks; so they are not in the app, and `verify-release.sh` checks the app against the macOS 26 SDK.
- `AVSampleBufferDisplayLayer` keeps the presentation time only if it got the picture about 20 ms ahead; hence the presentation schedule with lead time (see [VideoRecovery.md](../VideoRecovery.md)).
- On Apple Silicon the system frame generator does not accept frames above 1920×1080 and takes about 9 ms at 720p (about 40% longer on battery).
- A test build shares settings and window state with the installed app (same bundle identifier).

### Sony

- The list of datacenters comes only while a stream is being prepared; the last list and the chosen server are kept between launches.
- Sony picks a datacenter only if the declared latency to it is no more than 80 ms; when the measured one is higher, Con stops with an explanation, unless the player turned on Distant servers: then it sends 75 ms (`CloudPingPolicy`), a departure from the service's rules; see [FEATURES.md](FEATURES.md).
- The previous session's slot is not freed at once: HTTP 500 / 002.2008 on allocation repeats for up to a minute and a half.
- Not every game listens to "Game language": Cyberpunk 2077 stays in English with both `ru` and `de`.
