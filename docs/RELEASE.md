# Con: release preparation

## In place

- The "About Con" screen has no technical descriptions; component information is under "Licenses".
- The version number is taken from bundle metadata.
- The notices and licenses of static and dynamic dependencies are included in the package.
- `Scripts/verify-release.sh` checks the signature, resources, the sign-in storage component ([CredentialAgent/README.md](../CredentialAgent/README.md)) and external library paths.

## Current build

Con 0.5.1, build 27. Local signature Sole Local Development, without an Apple TeamIdentifier. The minimum system version in the bundle is macOS 26.0 (`Scripts/verify-release.sh` checks the app's files against the macOS 26 SDK); the engine is a static library from `Engine/build.sh`.

## Before public distribution

1. Set up Developer ID and notarization. The current Keychain helper trusts a specific local build certificate: changing the signature requires migrating the trust and the saved credentials, not simply substituting a new certificate in build.sh.
2. Test the installed build on a clean Mac with the stated OS version. Decide the supported macOS versions and architectures, and rebuild the engine (`Engine/build.sh`) for them. Do not lower LSMinimumSystemVersion without checking the native libraries.
3. Run real long sessions: cloud games, local Remote Play, relaunch and audio, button release, USB/Bluetooth DualSense, network drop and recovery, signing in again after an app update.
4. After these checks, choose a release version and prepare a signed installer package. No public download has been made yet.

There is no Android release yet: the Con app for Android (see [ANDROID.md](ANDROID.md)) is signed only with the local key `work/android/check-app.keystore`.

## Checking a local build

```sh
swift test --scratch-path work/sole-review-build
./build.sh
./Scripts/verify-release.sh
```
