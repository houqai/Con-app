#!/bin/sh
set -eu

PLATFORM=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$PLATFORM/.." && pwd)
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=~"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/work/platform-rust-target}"
OUT="${CON_PLATFORM_OUT:-$ROOT/work/platform-rust}"
CHECK="${CON_PLATFORM_CHECK:-1}"
MACOS_MIN=14.0
HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)
[ "$HOST_ARCH" = arm64 ] && HOST_ARCH=aarch64

say() { printf '%s\n' "$*" >&2; }

if [ "$#" -gt 0 ]; then
    TARGETS="$*"
elif [ "$HOST_OS" = Darwin ]; then
    TARGETS="aarch64-apple-darwin aarch64-linux-android x86_64-linux-android x86_64-pc-windows-msvc aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu"
else
    TARGETS="$HOST_ARCH-unknown-linux-gnu aarch64-linux-android x86_64-linux-android x86_64-pc-windows-msvc"
fi

host_target() {
    case "$HOST_OS" in
        Darwin) echo "$HOST_ARCH-apple-darwin" ;;
        *) echo "$HOST_ARCH-unknown-linux-gnu" ;;
    esac
}

lib_name() {
    case "$1" in
        *-windows-msvc) echo "${2:-con_platform}.lib" ;;
        *) echo "lib${2:-con_platform}.a" ;;
    esac
}

SYMBOLS="con_broadcast_address_texts con_wine_heap_active con_objc_catch con_test_udp_port_hold con_test_udp_port_release"
ANDROID_SYMBOLS="JNI_OnLoad Java_app_con_check_Shared_start Java_app_con_check_Shared_text Java_app_con_check_Shared_state Java_app_con_check_Shared_act Java_app_con_check_Shared_ask Java_app_con_check_Shared_loginFinished Java_app_con_check_Shared_loginClosed Java_app_con_check_Shared_surface Java_app_con_check_Shared_pad Java_app_con_check_Shared_padGone Java_app_con_check_Shared_touch Java_app_con_check_Shared_storeCheck con_java_store_read con_java_store_write con_java_store_remove con_java_open_login con_java_close_login con_java_changed con_java_activate con_java_keep_awake con_main_queue_attach con_video_window con_video_open con_video_submit con_video_decode_us con_video_counts con_video_ready con_video_close con_audio_open con_audio_write con_audio_counts con_audio_underruns con_audio_close"
ANDROID_CHECK_SYMBOLS="con_check_begin con_check_window_open con_check_window_pictures con_check_window_close con_check_encode"
DESKTOP_SYMBOLS="con_secret_store con_secret_lookup con_secret_clear con_image_decode con_video_open con_video_submit con_video_draw con_video_counts con_video_close con_video_forget"
XWIN="${CON_XWIN:-$ROOT/work/windows/xwin}"
WINDOWS_DEPS="${CON_WINDOWS_DEPS:-$ROOT/work/windows/deps}"
SWIFT_ORG="${SWIFT_ORG_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain}"

nm_tool() {
    for n in /opt/homebrew/opt/llvm/bin/llvm-nm "$SWIFT_ORG/usr/bin/llvm-nm" "$(command -v llvm-nm 2>/dev/null)"; do
        if [ -n "$n" ] && [ -x "$n" ]; then
            echo "$n"
            return
        fi
    done
    return 1
}

check_symbols() {
    t=$1
    lib=$2
    want=$3
    nm=$(nm_tool) || { say "  no llvm-nm: symbols not checked"; return 0; }
    case "$t" in *-apple-*) us=_ ;; *) us= ;; esac
    defined=$("$nm" -g --defined-only "$lib" 2>/dev/null | awk '{print $NF}')
    for s in $want; do
        printf '%s\n' "$defined" | grep -qx "$us$s" || { say "  $s is not defined in $lib"; return 1; }
    done
}

same_rust_as_engine() {
    t=$1
    lib=$2
    case "$t" in
        *-windows-msvc) engine="$ROOT/work/engine-rust/$t/con_engine.lib" ;;
        *) engine="$ROOT/work/engine-rust/$t/libcon_engine.a" ;;
    esac
    [ -f "$engine" ] || { say "  no engine library for $t: Rust toolchain match not checked"; return 0; }
    ar=$(dirname "$(nm_tool)")/llvm-ar
    [ -x "$ar" ] || { say "  no llvm-ar: Rust toolchain match not checked"; return 0; }
    ours=$("$ar" t "$lib" | grep -E '^std-' | sort -u)
    theirs=$("$ar" t "$engine" | grep -E '^std-' | sort -u)
    if [ "$ours" != "$theirs" ]; then
        say "  the engine ($engine) was built with a different Rust toolchain than this library ($(rustc --version)):"
        say "  rebuild one of them with the same toolchain (Engine/build.sh $t)"
        return 1
    fi
}

CBINDGEN_VERSION=0.29.4

header() {
    cbindgen=""
    for c in "${CBINDGEN:-}" "$(command -v cbindgen 2>/dev/null || true)" "${CARGO_HOME:-$HOME/.cargo}/bin/cbindgen"; do
        if [ -n "$c" ] && [ -x "$c" ] && [ "$("$c" --version 2>/dev/null)" = "cbindgen $CBINDGEN_VERSION" ]; then
            cbindgen=$c
            break
        fi
    done
    if [ -z "$cbindgen" ]; then
        say "== cbindgen $CBINDGEN_VERSION (cargo install cbindgen --version $CBINDGEN_VERSION --locked)"
        cargo install --quiet cbindgen --version "$CBINDGEN_VERSION" --locked >&2
        cbindgen="${CARGO_HOME:-$HOME/.cargo}/bin/cbindgen"
    fi
    mkdir -p "$OUT/include"
    for crate in con-platform:. con-desktop:desktop con-android:android con-android-check:android-check; do
        name=${crate%%:*}
        folder=${crate#*:}
        h="$OUT/include/$(printf '%s' "$name" | tr - _).h"
        (cd "$PLATFORM/$folder" && "$cbindgen" --quiet --config cbindgen.toml --crate "$name" --output "$h.new" .)
        if cmp -s "$h.new" "$h"; then
            rm -f "$h.new"
        else
            mv "$h.new" "$h"
        fi
        say "  $h"
    done
}

desktop_setup() {
    t=$1
    case "$t" in
        *-unknown-linux-gnu)
            if [ "$HOST_OS" != Linux ] || [ "${t%%-*}" != "$HOST_ARCH" ]; then
                say "  skipping desktop libraries for $t: they must be built on Linux of the same architecture (GTK, WebKit and FFmpeg come from the system)"
                return 1
            fi
            ;;
        x86_64-pc-windows-msvc)
            if [ ! -d "$XWIN/crt/lib/x86_64" ] || [ ! -d "$WINDOWS_DEPS/include/libavcodec" ]; then
                say "  skipping desktop libraries for $t: run Scripts/windows-sdk.sh and Scripts/windows-deps.sh first"
                return 1
            fi
            for linker in "$SWIFT_ORG/usr/bin/lld-link" "$(command -v lld-link 2>/dev/null || true)"; do
                if [ -n "$linker" ] && [ -x "$linker" ]; then
                    export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$linker"
                    break
                fi
            done
            [ -n "${CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER:-}" ] || { say "  skipping desktop libraries for $t: lld-link not found"; return 1; }
            if [ -z "${LIBCLANG_PATH:-}" ]; then
                for folder in "$SWIFT_ORG/usr/lib" /opt/homebrew/opt/llvm/lib; do
                    if [ -f "$folder/libclang.dylib" ] || [ -f "$folder/libclang.so" ]; then
                        export LIBCLANG_PATH="$folder"
                        break
                    fi
                done
            fi
            export BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_msvc="-I$WINDOWS_DEPS/include -idirafter $XWIN/crt/include -idirafter $XWIN/sdk/include/ucrt -idirafter $XWIN/sdk/include/um -idirafter $XWIN/sdk/include/shared"
            export CON_LOGIN_LIBRARY_DIRS="$XWIN/crt/lib/x86_64;$XWIN/sdk/lib/um/x86_64;$XWIN/sdk/lib/ucrt/x86_64"
            if [ "$HOST_OS" = Darwin ]; then
                CON_LOGIN_RESOURCES=$("$ROOT/Scripts/windows-icon.sh") || { say "  no icon for con-login.exe"; CON_LOGIN_RESOURCES=""; }
                export CON_LOGIN_RESOURCES
            fi
            ;;
        *) return 1 ;;
    esac
}

build_lib() {
    t=$1
    dest=$2
    crate=$3
    file=$4
    libs_file=$5
    symbols=$6
    log=$(mktemp "${TMPDIR:-/tmp}/con-platform-build.XXXXXX")
    if ! (cd "$PLATFORM" && cargo rustc ${crate:+-p "$crate"} --release --lib --target "$t" -- --print native-static-libs) >"$log" 2>&1; then
        tail -40 "$log" >&2
        rm -f "$log"
        return 1
    fi
    libs=$(sed -n 's/.*native-static-libs: //p' "$log" | tail -1)
    rm -f "$log"
    case "$t:$crate" in
        *-linux-gnu:con-desktop) libs="$(pkg-config --libs-only-L libavcodec libavutil libswscale libsecret-1 sdl2 2>/dev/null) $libs" ;;
    esac
    cp "$CARGO_TARGET_DIR/$t/release/$file" "$dest/$file" || return 1
    printf '%s\n' "$libs" >"$dest/$libs_file" || return 1
    check_symbols "$t" "$dest/$file" "$symbols" || return 1
    same_rust_as_engine "$t" "$dest/$file" || return 1
    say "  $dest/$file ($(du -h "$dest/$file" | cut -f1))"
    say "  link with: $libs"
}

build_desktop() {
    t=$1
    dest=$2
    build_lib "$t" "$dest" con-desktop "$(lib_name "$t" con_desktop)" native-libs-desktop.txt "$DESKTOP_SYMBOLS" || return 1
    (cd "$PLATFORM" && cargo build --quiet -p con-login --release --target "$t") >&2 || return 1
    case "$t" in *-windows-*) login=con-login.exe ;; *) login=con-login ;; esac
    cp "$CARGO_TARGET_DIR/$t/release/$login" "$dest/$login" || return 1
    say "  $dest/$login ($(du -h "$dest/$login" | cut -f1))"
}

build_android() {
    t=$1
    dest=$2
    for part in con-android:con_android:native-libs-android.txt:"$ANDROID_SYMBOLS" con-android-check:con_android_check:native-libs-android-check.txt:"$ANDROID_CHECK_SYMBOLS"; do
        crate=${part%%:*}
        rest=${part#*:}
        name=${rest%%:*}
        rest=${rest#*:}
        libs_file=${rest%%:*}
        symbols=${rest#*:}
        build_lib "$t" "$dest" "$crate" "$(lib_name "$t" "$name")" "$libs_file" "$symbols" || return 1
    done
}

build_target() {
    t=$1
    say "== $t"
    if ! rustup target list --installed 2>/dev/null | grep -qx "$t"; then
        rustup target add "$t" >&2
    fi
    (
        case "$t" in *-apple-darwin) export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN ;; esac
        dest="$OUT/$t"
        mkdir -p "$dest" || exit 1
        case "$t" in
            *-windows-*) symbols="$SYMBOLS con_wine_heap_start" ;;
            *) symbols=$SYMBOLS ;;
        esac
        build_lib "$t" "$dest" "" "$(lib_name "$t")" native-libs.txt "$symbols" || exit 1
        case "$t" in
            *-linux-android) build_android "$t" "$dest" || exit 1 ;;
        esac
        desktop=0
        if desktop_setup "$t"; then
            build_desktop "$t" "$dest" || exit 1
            desktop=1
        else
            rm -f "$dest/$(lib_name "$t" con_desktop)" "$dest/native-libs-desktop.txt" "$dest/con-login" "$dest/con-login.exe"
        fi
        if [ "$CHECK" = 1 ] && [ "$t" = "$(host_target)" ]; then
            if [ "$desktop" = 1 ]; then tested="--workspace"; else tested="-p con-platform -p con-login"; fi
            (cd "$PLATFORM" && cargo test --release --quiet --target "$t" $tested) >&2 || exit 1
        fi
    )
}

header
failed=""
built=""
for t in $TARGETS; do
    if build_target "$t"; then
        built="$built $t"
    else
        say "  FAILED: $t"
        failed="$failed $t"
    fi
done
say ""
say "built:${built:- none}"
[ -z "$failed" ] || { say "failed:$failed"; exit 1; }
