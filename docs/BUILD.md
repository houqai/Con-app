# Building and checking

Everything runs from the project folder. The scripts change into it themselves, so they can also be called by full path.

## Folder layout

```
Con/                      ← project root and git repository root
├── Package.swift         ← build description (SwiftPM)
├── Sources/ Tests/ Tools/ Scripts/ Engine/ Android/ …
├── Engine/               ← engine (Rust): sources, header, Engine/build.sh
├── Platform/             ← Con's platform code (Rust): networks, heap under Wine, ObjC exceptions; for Linux and
│                           Windows — desktop/ (keyring, FFmpeg, SDL texture) and login/ (con-login); for Android —
│                           android/ (JNI, MediaCodec, AAudio) and android-check/; Platform/build.sh
├── build.sh              ← macOS app
├── Con.app               ← built app                       (not in git)
└── work/                 ← everything the build needs that is not part of the project (not in git)
    ├── sole-signing/         local signing and the built sign-in storage component
    ├── sole-build/           app build (release)
    ├── sole-review-build/    test build
    ├── sole-linux-build/, sole-android-build/   builds for other systems
    ├── engine-rust/<target>/ engine library (Engine/build.sh) for each system
    ├── engine-rust-target/   intermediate engine build (can be deleted)
    ├── platform-rust/<target>/ platform code library (Platform/build.sh) for each system;
    │   platform-rust/include/con_platform.h — its C interface (cbindgen), one for all;
    │   for Linux and Windows, also libcon_desktop.a / con_desktop.lib, con-login, include/con_desktop.h
    ├── platform-rust-target/ intermediate platform code build (can be deleted)
    ├── android/              libConShared.so, the APK and its signing key for Android
    ├── swift-toolchain/android-ndk-r30/   Android NDK
    ├── android-sdk/jdk/      JDK 21 for building the APK
    └── sole-*-checks/        measurement tools and their logs
```

Engine: `Engine/build.sh` (all targets this Mac can build) or `Engine/build.sh <target>`; libraries go to `work/engine-rust/<target>`, the intermediate build to `work/engine-rust-target` (it can be deleted). Without the engine library the build stops at linking and names the missing file. A different library folder: the `CON_ENGINE_LIB` variable.

Con's platform code: `Platform/build.sh` (all targets) or `Platform/build.sh <target>`; libraries go to `work/platform-rust/<target>`, the C interface to `work/platform-rust/include/con_platform.h` (without it Swift cannot find the `CConPlatform` module), the intermediate build to `work/platform-rust-target` (can be deleted). A different library folder: `CON_PLATFORM_LIB`. Build with the same Rust as the engine: the script checks and stops otherwise. For Android the same script builds the Android layer: the libraries `con_android` (JNI, MediaCodec, AAudio; module `CConAndroid`, `con_android.h`; linked only with `SoleAndroid`) and `con_android_check` (for `ConAndroidCheck`, `con_android_check.h`). For Linux and Windows the same script builds the shell parts: the `con_desktop` library (module `CConDesktop`, `con_desktop.h`; linked only with the app) and the `con-login` sign-in window. For Linux — only on Linux of the same architecture (needs the development packages of GTK 4, WebKitGTK 6, FFmpeg, SDL 2, libsecret and libclang for bindgen); a Linux library built on a Mac does not contain them. For Windows — on a Mac after `Scripts/windows-sdk.sh` and `Scripts/windows-deps.sh` (bindgen takes libclang and `lld-link` from the swift.org toolchain; the icon comes from `Scripts/windows-icon.sh`).

The build folders in `work/` are created automatically; they can be deleted, and the next build recreates them. **Do not lose** `work/sole-signing` (see "Signing") and `work/android/check-app.keystore` (the signing key of the check APK: with a different key Android will not update the app in place, it has to be uninstalled, and the sign-in on the phone is lost).

## What the Mac needs

| What | Why | Where from |
|---|---|---|
| Xcode with Swift 6 and command line tools | Everything for macOS | App Store |
| macOS 26 SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` | Check "the app asks the system for nothing beyond what macOS 26 has" | Command Line Tools; another path: the `CON_OLDEST_SDK` variable |
| Rust (`rustup`, `cargo`) | Building the engine and the platform code; `Engine/build.sh` and `Platform/build.sh` add the targets for other systems themselves | rustup.rs |
| cbindgen 0.29.4 (the same version as the engine's) | C interface of the platform code; if missing, `Platform/build.sh` installs it itself (`cargo install cbindgen --version 0.29.4 --locked`) | crates.io |
| Homebrew: `cmake` | libopus inside the engine | `brew install cmake` |
| Homebrew: `ninja`, `llvm` | Engine for Android and Windows; `llvm-rc` for the Windows program icon | `brew install ninja llvm` |
| Local signing | `build.sh` | see "Signing" |

The macOS app has no third-party libraries: the engine is one static library (`work/engine-rust/aarch64-apple-darwin`) with its own libopus inside, the platform code is another (`work/platform-rust/aarch64-apple-darwin`).

For other systems, additionally:

| What | Where it must be | Why |
|---|---|---|
| swift.org toolchain 6.4.0 | `~/Library/Developer/Toolchains/swift-latest.xctoolchain` (or `SWIFT_ORG_TOOLCHAIN`) | Building for systems other than macOS; Xcode stays the default compiler |
| Swift SDK: Static Linux 0.1.0 and Android 6.4.0 | Installed with `swift sdk install` into `~/Library/org.swift.swiftpm/swift-sdks` | Linux and Android |
| Android NDK r30 | `work/swift-toolchain/android-ndk-r30` (or `ANDROID_NDK_HOME`) | Engine and shared code for Android |
| JDK 21 (Temurin) | `work/android-sdk/jdk` (or `JAVA_HOME`) | Building the APK |
| Android SDK: build-tools, platform, platform-tools | `~/Library/Android/sdk` (or `ANDROID_SDK`, `ADB`) | Building the APK, `adb` |

## macOS app

```sh
swift test --scratch-path work/sole-review-build
./build.sh
./Scripts/verify-release.sh
```

- `swift test` runs all XCTest and Swift Testing tests. The video tests run in real time and can fail once under heavy load or on battery; rerun them. The audio and timing tests do not pass while the Mac is asleep.
- `./build.sh` builds release, puts `Con.app` in the project folder, puts third-party libraries into it if any appear (`Scripts/bundle-runtime.py`; there are none now) and the sign-in storage component, and signs everything with one signature.
- `./Scripts/verify-release.sh` checks the signature, the resources, the storage component, the absence of `/opt/homebrew` paths, and that everything requested from the system exists in the macOS 26 SDK (`Scripts/check-older-macos.py`).

Do not run `./build.sh` while the installed Con is open: it replaces `Con.app` in place.

### Signing

`build.sh` signs either with the certificate from the `CON_SIGNING_IDENTITY` variable or with the local signing from `work/sole-signing` (the "Sole Local Development" certificate, its own keychain `signing.keychain-db`, its password in the `password` file; another folder: `CON_SIGNING_DIR`). There is no fallback to ad-hoc signing: without signing the build stops. The build folder is `work/sole-build` (another one: `CON_BUILD_DIR`). The older names of these variables, `SOLE_SIGNING_IDENTITY`, `SOLE_SIGNING_DIR`, `SOLE_BUILD_DIR` and `SOLE_OLDEST_SDK`, are still read when the new ones are not set.

Why this matters: the sign-in is stored in the Keychain, and access to it is tied to the signature. It is held by a separate file, `SoleCredentialAgent`, which **is not rebuilt**: `build.sh` takes the ready one from `work/sole-signing` and checks that the source (`CredentialAgent/main.swift`) has not changed. As long as the file is byte-for-byte the same, the sign-in survives app rebuilds. If `work/sole-signing` is lost or the component's source is changed, you will have to sign in again once; the component may only be changed together with migrating the entries (see [CredentialAgent/README.md](../CredentialAgent/README.md)).

`work/sole-signing` does not go into the repository: it holds the private key.

## Engine

```sh
Engine/build.sh aarch64-apple-darwin     # for macOS; without a target — all this Mac can build
Platform/build.sh aarch64-apple-darwin   # Con's platform code, the same way
```

The engine is `Engine/` (Rust, Con's own code, written from the protocol description in `docs/protocol`). Its C interface is generated by cbindgen from `Engine/src/ffi` during `Engine/build.sh`: `work/engine-rust/include/con_engine.h` (and a copy next to each library), the `CConEngine` module in Swift. What the engine does not do itself (the list of the computer's networks for finding consoles) and what else Swift needs from the system (heap under Wine, Objective-C exceptions) is Con's platform code `Platform/` (Rust), the `CConPlatform` module. Tests: `cd Engine && cargo test`, `cd Platform && cargo test` (on a Mac; `Platform/build.sh` for this Mac's target runs them itself).

## Other systems: compile check

```sh
./Scripts/check-shared-systems.sh    # shared code: Linux and Android, ARM and Intel
```

Compiles only. Android, Linux and Windows are built in full — see below.

## Android

Order from scratch (a device connected over USB with debugging enabled; several devices — `ANDROID_SERIAL`):

```sh
Engine/build.sh aarch64-linux-android # engine → work/engine-rust/aarch64-linux-android
Platform/build.sh aarch64-linux-android # platform code → work/platform-rust/aarch64-linux-android
./Scripts/build-shared-android.sh     # shared code + engine → work/android/arm64-v8a/libConShared.so
./Scripts/build-android-check-app.sh  # Con app for Android → work/android/arm64-v8a/con-check.apk
./Scripts/run-android-check-app.sh    # install, launch, wait for the catalog
```

On Android the system may refuse the engine thread priority (nice −8) to a program run from `adb shell`; the test then only checks that the thread requested it.

Checks on the device:

| Script | What it checks |
|---|---|
| `Scripts/test-shared-android.sh` | Shared code tests (the same as on macOS, except those that read the project sources). |
| `Scripts/check-android-run.sh` | Shared code next to the engine in one process: settings, certificates, requests to Sony without signing in; the H.264 and HEVC decoder and audio without a stream and without a screen. |
| `Scripts/run-android-check-app.sh [language]` | The app installs, launches, reads the catalog. `SHOT=1` — take a screenshot. |
| `Scripts/check-android-stream.sh "<part of the title>" [seconds]` | One live run of a cloud game on the account signed in on the device. Does not run while the screen is off or locked. |

More on the Android layer — [ANDROID.md](ANDROID.md).

## Linux

Built on the Linux machine itself; from a Mac — via `Scripts/linux-vm.sh`. More — [LINUX.md](LINUX.md).

```sh
Engine/build.sh $(uname -m)-unknown-linux-gnu     # or copy the one built on the Mac into work/engine-rust/
Platform/build.sh $(uname -m)-unknown-linux-gnu   # here too: the shell parts and con-login build only on Linux
./Scripts/build-linux.sh
```

## Windows

Built on a Mac (swift.org toolchain, Windows SDK via xwin), checked under Wine in CrossOver. More — [WINDOWS.md](WINDOWS.md).

```sh
Scripts/windows-sdk.sh && Scripts/windows-deps.sh
Engine/build.sh x86_64-pc-windows-msvc     # engine
Platform/build.sh x86_64-pc-windows-msvc   # platform code, con_desktop.lib and con-login.exe
Scripts/build-windows.sh                 # → work/windows/Con-windows-x64
Scripts/test-shared-windows.sh
```

## All scripts

| Script | Purpose |
|---|---|
| `build.sh` | macOS app: build, libraries, signing. |
| `Engine/build.sh [target …]` | Engine: static library and header for each system. |
| `Platform/build.sh [target …]` | Con's platform code: static library for each system and the C interface (cbindgen); for Android also `con_android` and `con_android_check`; for Linux (on Linux) and Windows the shell library `con_desktop` and the `con-login` sign-in window. |
| `Scripts/windows-icon.sh` | Windows icon from the Con logo (resource for `con-app.exe` and `con-login.exe`). |
| `Scripts/verify-release.sh` | Checks the built `Con.app`. |
| `Scripts/bundle-runtime.py` | Puts third-party libraries into the app and fixes the paths to them (called by `build.sh`). |
| `Scripts/check-older-macos.py` | Checks what the app's files request from the system against the SDK of an older macOS. |
| `Scripts/check-shared-systems.sh`, `check-shared-sdk.sh` | Compiling the shared code for Linux and Android (`SWIFT_SDK=<name> Scripts/check-shared-sdk.sh` — for one Swift SDK). |
| `Scripts/build-shared-android.sh` | `libConShared.so`. |
| `Scripts/check-android-library.py` | Checks that the library asks Android for nothing it lacks and exports to Java `JNI_OnLoad` and all native methods of `Shared.java`. |
| `Scripts/build-android-check-app.sh`, `run-android-check-app.sh` | Con app for Android: build (with the icon and licenses); install over the previous one and launch. |
| `Scripts/test-shared-android.sh`, `check-android-run.sh`, `check-android-stream.sh` | Checks on an Android device. |
| `Scripts/build-linux.sh`, `Scripts/check-linux-stream.sh` | Linux: app, live run (on the Linux machine). |
| `Scripts/linux-vm.sh '<command>'` | Copy the project to the Linux virtual machine and run a command there. |
| `Linux/flatpak/build-flatpak.sh` | Flatpak package (Steam Deck); on Linux of the same architecture. Not built yet; the engine and platform code crates (and cbindgen) are downloaded from crates.io during the build. |
| `Linux/install-apparmor.sh` | AppArmor profile for the sign-in window on Ubuntu 23.10+ (with `sudo`, on Linux). |
| `Scripts/android-env.sh`, `Scripts/windows-env.sh` | Common part of the Android and Windows scripts (paths, the Swift version for Windows, checks of the engine and platform code libraries); read by those scripts, not run on their own. |
| `Scripts/windows-sdk.sh`, `Scripts/windows-deps.sh` | Windows: Swift SDK (Microsoft Windows SDK via xwin + Swift libraries), the app's libraries (SDL 2, FFmpeg, Cairo/Pango, WebView2, Inter). |
| `Scripts/build-windows.sh` | Windows: app (`work/windows/Con-windows-x64`, `zip`). |
| `Scripts/test-shared-windows.sh` | Windows: shared code tests — under Wine (CrossOver, bottle `con-test`). |
| `Tools/Translations/make-tables.py <code> …` | Checks the translation lists and writes the tables in `Sources/SoleCore/Translations`. |

## From scratch on another Mac

1. Clone the repository, install Xcode, Rust and the Homebrew tools from the table; `Engine/build.sh aarch64-apple-darwin`, `Platform/build.sh aarch64-apple-darwin`.
2. Create a code signing certificate and set `CON_SIGNING_IDENTITY`, or copy an existing `work/sole-signing` folder (with a new certificate the sign-in has to be repeated once).
3. `swift test --scratch-path work/sole-review-build`, then `./build.sh` and `./Scripts/verify-release.sh`.
4. For Android: install the swift.org toolchain and the two Swift SDKs, put the NDK and JDK at the paths from the table, then the four commands from the "Android" section. The signing key of the check APK is created on the first build.

To move a built `Con.app` to another Mac, use an archive: `ditto -c -k --sequesterRsrc --keepParent Con.app Con.zip`; a plain zip sent through a messenger loses the execute permissions. On that Mac, remove the quarantine once: `xattr -cr Con.app`.

## If the build fails

| What you see | Cause |
|---|---|
| `Missing local signing identity` | There is no `work/sole-signing` and `CON_SIGNING_IDENTITY` is not set. |
| `Credential agent changed…` | `CredentialAgent/main.swift` was changed, but the ready component is from the previous source. Do not replace it without migrating the entries. |
| `no such file or directory: …/libcon_engine.a` (or `con_engine.lib`) | No engine library for this system: `Engine/build.sh <target>`. |
| `…/libcon_platform.a` (or `con_platform.lib`) not found; `header '…/con_platform.h' not found` | No platform code library or C interface: `Platform/build.sh <target>`. |
| `duplicate symbol: rust_eh_personality` and similar | The engine and the platform code were built with different Rust versions: rebuild one of them. |
| `macOS 26 SDK not found: system symbol check skipped` (from `verify-release.sh`) | No macOS 26 SDK at the default path; install it or set `CON_OLDEST_SDK`. |
| `No Android device answers` | The device is not connected, USB debugging is not allowed, or there are several devices (`ANDROID_SERIAL`). |
| After moving the project folder the build complains about paths | `work/` still has builds with the old paths: delete the build folders (`sole-build`, `sole-review-build`, `sole-android-build`, `sole-linux-build`, `engine-rust-target`, `platform-rust-target`). |
