WORK="$(mkdir -p work && cd work && pwd)"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$WORK/swift-toolchain/android-ndk-r30}"
SWIFT="${SWIFT_ORG_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain}/usr/bin/swift"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SCRATCH="$WORK/sole-android-build"
android_abi() {
  ABI="$1"
  case "$ABI" in
    arm64-v8a) ARCH=aarch64 ;;
    x86_64) ARCH=x86_64 ;;
    *) echo "Unknown ABI $ABI (arm64-v8a, x86_64)." >&2; exit 2 ;;
  esac
  RUST_TARGET="$ARCH-linux-android"
  TRIPLE="$ARCH-unknown-linux-android28"
}
android_libraries() {
  export CON_SYSTEM=android
  export CON_ENGINE_LIB="${CON_ENGINE_LIB:-$WORK/engine-rust/$RUST_TARGET}"
  [[ -f "$CON_ENGINE_LIB/libcon_engine.a" ]] || { echo "No engine for Android $ABI: run Engine/build.sh $RUST_TARGET first." >&2; exit 2; }
  export CON_PLATFORM_LIB="${CON_PLATFORM_LIB:-$WORK/platform-rust/$RUST_TARGET}"
  local built
  for built in "$CON_PLATFORM_LIB/libcon_platform.a" "$CON_PLATFORM_LIB/libcon_android.a" "$CON_PLATFORM_LIB/libcon_android_check.a" \
      "$WORK/platform-rust/include/con_platform.h" "$WORK/platform-rust/include/con_android.h" "$WORK/platform-rust/include/con_android_check.h"; do
    [[ -f "$built" ]] || { echo "No platform code for Android $ABI ($built): run Platform/build.sh $RUST_TARGET first." >&2; exit 2; }
  done
}
android_runtime() {
  RUNTIME="$(ls -d "$HOME"/Library/org.swift.swiftpm/swift-sdks/*android*/swift-android/swift-resources/usr/lib/swift-$ARCH/android 2>/dev/null | tail -1 || true)"
  [[ -f "$RUNTIME/libswiftCore.so" ]] || { echo "No Swift libraries for Android $ABI in the Swift SDK for Android." >&2; exit 2; }
  LIBCXX="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* | head -1)/sysroot/usr/lib/$ARCH-linux-android/libc++_shared.so"
}
android_device() {
  SERIAL="${ANDROID_SERIAL:-$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
  [[ -n "$SERIAL" ]] && "$ADB" -s "$SERIAL" get-state > /dev/null 2>&1 || { echo "No Android device answers: connect one by USB with debugging allowed (ANDROID_SERIAL names one of several)." >&2; exit 2; }
}
adb() { "$ADB" -s "$SERIAL" "$@"; }
android_device_name() {
  echo "$(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r')"
}
