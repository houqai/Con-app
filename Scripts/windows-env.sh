ROOT="$(pwd)"
W="$(mkdir -p "$ROOT/work/windows" && cd "$ROOT/work/windows" && pwd)"
SWIFT_VERSION=6.4.0
TOOLS="${CON_SWIFT_TOOLCHAIN:-${SWIFT_ORG_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain}}/usr/bin"
DEPS="$W/deps"
windows_libraries() {
  export CON_SYSTEM=windows
  export CON_ENGINE_LIB="${CON_ENGINE_LIB:-$ROOT/work/engine-rust/x86_64-pc-windows-msvc}"
  [[ -f "$CON_ENGINE_LIB/con_engine.lib" ]] || { echo "No engine for Windows: run Engine/build.sh x86_64-pc-windows-msvc first." >&2; exit 2; }
  export CON_PLATFORM_LIB="${CON_PLATFORM_LIB:-$ROOT/work/platform-rust/x86_64-pc-windows-msvc}"
  [[ -f "$CON_PLATFORM_LIB/con_platform.lib" && -f "$ROOT/work/platform-rust/include/con_platform.h" ]] || { echo "No platform code for Windows: run Platform/build.sh x86_64-pc-windows-msvc first." >&2; exit 2; }
}
