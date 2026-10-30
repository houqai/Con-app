# Con 0.5.1

A native PlayStation client for macOS: PS Plus cloud games (PS5, PS4 "PS Now", PS3) and Remote Play with your own console. The interface is SwiftUI, the stream is received by Con's own engine in Rust (`Engine/`), and everything else is Con's own Swift code.

The same shared code runs on Android: the Con app for Android, with screens modeled on the Mac (library, game page, settings, sign-in, consoles, stream with a menu), signs in to the account, shows the catalog and plays a cloud stream. It has been checked on one phone and is not ready for distribution. The Linux version (ordinary PC and Steam Deck) works from sign-in to stream on Ubuntu (aarch64, virtual machine); there is no build for x86_64 and no package yet, see [docs/LINUX.md](LINUX.md). The Windows version (x64) is built on the Mac with the same shell as Linux; on Windows 11 sign-in and cloud streaming work, and the shared code tests pass under Wine (CrossOver), see [docs/WINDOWS.md](WINDOWS.md).

## What there is

- Sign-in through Sony's page, profile, game history, PS5 / PS4 / PS3 cloud catalogs, search, favorites, the "Purchased" filter.
- Launching a cloud game: license check, session, datacenter choice by measured latency, slot, HEVC / H.264 stream with sound.
- Remote Play: finding consoles on the network, console registration by code, stream.
- Controls: gamepad (DualSense with rumble, triggers and light bar), keyboard, mouse camera; the whole interface can be used with a gamepad.
- Video: recovery after lost frames without waiting for a keyframe, even presentation rhythm, generation of intermediate frames (macOS 26+).
- Interface in 11 languages, the same languages as "Game language".
- Sign-in and console keys are in the Keychain, through a separate unchanging component.

In detail, with how each feature has been checked and where its limits are: [docs/FEATURES.md](FEATURES.md).

## Quick start

You need Xcode (Swift 6), Rust, Homebrew `cmake` and a local signing identity in `work/sole-signing`. Everything else is in [docs/BUILD.md](BUILD.md).

```sh
Engine/build.sh aarch64-apple-darwin               # engine → work/engine-rust/aarch64-apple-darwin
Platform/build.sh aarch64-apple-darwin             # platform code → work/platform-rust/aarch64-apple-darwin
swift test --scratch-path work/sole-review-build   # all tests
./build.sh                                         # builds and signs Con.app in the project folder
./Scripts/verify-release.sh                        # checks the built app
```

Cloud game: sign in, open the game page, "Play". Console: turn on Remote Play on it, "Link Device", enter the eight-digit code in the "My consoles" section.

## Repository map

| Path | What is there |
|---|---|
| `Sources/SoleCore` | Shared code without Sony's network and without the system: parsing PSN and Store answers, texts and translations, reading the video stream, presentation schedule, picture and sound queues. |
| `Sources/SoleCloud` | The PS Cloud protocol: session, licenses, datacenters, slot allocation, the PS Plus PC catalog. |
| `Sources/SoleEngine`, `Sources/CConEngine` | Swift wrapper of the engine: finding consoles, console registration, stream session, measurement to datacenters, keyboard layout, DualSense; the engine's C interface as a Swift module. |
| `Sources/SoleLogic` | App behavior: app model, stream model, library, sign-in, cloud game launch order. |
| `Sources/SoleMedia`, `Sources/Sole` | macOS layer: decoder, presentation, sound, SwiftUI interface, Keychain. |
| `Sources/SoleAndroid`, `Sources/CConAndroid`, `Platform/android` | Android layer: the app models on Android and what their screens see (Swift); the bridge to Java (JNI), decoder and sound (Rust, `Platform/android`, module `CConAndroid`). |
| `Engine` | The engine in Rust: receiving the Remote Play and PS Cloud stream, discovery, console registration, measurement; C interface (`include/con_engine.h`), build for all systems (`build.sh`). |
| `CredentialAgent` | The component that stores the sign-in in the Keychain. |
| `Sources/ConDesktop`, `Sources/CConDesktop`, `Sources/CSystem`, `Platform/desktop`, `Platform/login`, `Linux` | Linux and Windows layer: the app on SDL 2 and Cairo; in Rust, the keyring (libsecret / Credential Manager), FFmpeg and the SDL texture (`Platform/desktop`, module `CConDesktop`) and the sign-in window `con-login` (WebKitGTK / WebView2, `Platform/login`); SDL 2 and Cairo modules for Swift, the AppArmor profile. |
| `Platform`, `Sources/CConPlatform` | Con's platform code in Rust: the list of the computer's networks for finding consoles, under Wine memory for Swift above 2 GB (otherwise Swift 6.4 strings break), catching Objective-C exceptions, a port for tests; build for all systems (`build.sh`), C interface (cbindgen) as a Swift module. |
| `Android/CheckApp` | The Con app for Android: screens in Java modeled on the Mac, without Gradle (the folder and package come from the check app it grew out of). |
| `Tests` | Module tests (the engine's own tests are in `Engine/tests`). |
| `Tools` | Checking the shared code on an Android device, translation lists and their generator. |
| `Scripts`, `build.sh` | Building, checks, running on a device. |
| `docs`, `*.md` | Documentation (see below). |

Not in the repository (see `.gitignore`): `work/`, engine and app builds, Android and Windows tools, local signing, measurement tools with their logs; `Con.app`, the built app.

## Documentation

| Document | About |
|---|---|
| [docs/FEATURES.md](FEATURES.md) | Features, what has been checked, known limits. |
| [docs/ARCHITECTURE.md](ARCHITECTURE.md) | Layers, modules, shell protocols, the path of a game launch and a stream, storage, threads. |
| [docs/BUILD.md](BUILD.md) | Requirements, folder layout, building the app, the engine and Android, all scripts, installing from scratch. |
| [docs/DEVELOPMENT.md](DEVELOPMENT.md) | Code and test rules, texts and translations, working with the engine, live runs, known pitfalls. |
| [docs/LINUX.md](LINUX.md) | Linux layer: structure, building, Ubuntu and the sign-in window, checks, status, what is missing. |
| [docs/WINDOWS.md](WINDOWS.md) | Windows version: building on the Mac, checking under Wine, what had to be done for Wine and Windows, status, what is missing. |
| [docs/ANDROID.md](ANDROID.md) | Android layer: bridge, app screens, checks on a device, what is missing. |
| [Porting.md](../Porting.md) | Porting to other systems: what is shared, what is written per system, state by system. |
| [SoleCloud.md](../SoleCloud.md) | The PS Cloud protocol and how it is implemented. |
| [VideoRecovery.md](../VideoRecovery.md) | Frame losses, recovery, presentation rhythm: analysis and measurements. |
| [docs/protocol](protocol/README.md) | Description of the protocol the engine is written from, and the clean-room method used to write it. |
| [CredentialAgent/README.md](../CredentialAgent/README.md) | The sign-in storage component. |
| [docs/RELEASE.md](RELEASE.md) | What is in place and what is left before distribution. |

## Third-party code

The engine is Con's own (`Engine/`), written from the protocol description by the clean-room method. It uses open-source Rust libraries and libopus; their licenses are in [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

## About the name

The app used to be called Sole. The modules (`Sole`, `SoleCore`, …), the identifier `app.sole.desktop`, the settings keys `sole.*` and the cache folder `~/Library/Caches/Sole` kept the former name so that settings and Keychain access are not lost.
