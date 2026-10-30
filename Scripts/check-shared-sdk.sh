#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLCHAIN="${SWIFT_ORG_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain}"
SDK="${SWIFT_SDK:-aarch64-swift-linux-musl}"
SWIFT="$TOOLCHAIN/usr/bin/swift"
[[ -x "$SWIFT" ]] || { echo "No swift.org compiler at $TOOLCHAIN. See docs/BUILD.md."; exit 2; }
[[ -n "$("$SWIFT" sdk list 2>/dev/null)" ]] || { echo "No Swift SDK is installed for the swift.org compiler. See docs/BUILD.md."; exit 2; }
[[ -f work/platform-rust/include/con_platform.h ]] || { echo "No C interface of the platform code: run Platform/build.sh (any target) first."; exit 2; }
SCRATCH=work/sole-linux-build
if [[ "$SDK" == *android* ]]; then
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(cd work/swift-toolchain 2>/dev/null && pwd)/android-ndk-r30}"
  [[ -d "$ANDROID_NDK_HOME" ]] || { echo "No Android NDK at $ANDROID_NDK_HOME. See docs/BUILD.md."; exit 2; }
  SCRATCH=work/sole-android-build
fi
for module in SoleCore SoleCloud SoleEngine SoleLogic; do
  if ! output=$("$SWIFT" build --swift-sdk "$SDK" --target "$module" --scratch-path "$SCRATCH" 2>&1); then
    echo "$output" | grep "error:" | sort -u | head -40
    echo "$module does not compile for $SDK"
    exit 1
  fi
done
echo "The shared modules compile for $SDK."
