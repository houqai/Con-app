#!/bin/sh
set -eu

ENGINE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$ENGINE/.." && pwd)
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=~"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/work/engine-rust-target}"
OUT="${CON_ENGINE_OUT:-$ROOT/work/engine-rust}"
NDK="${ANDROID_NDK_HOME:-$ROOT/work/swift-toolchain/android-ndk-r30}"
XWIN="${CON_XWIN:-$ROOT/work/windows/xwin}"
SWIFT_ORG="${SWIFT_ORG_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain}"
LINUX_HEADERS="${CON_LINUX_HEADERS:-$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle/swift-6.4.0-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk}"
CHECK="${CON_ENGINE_CHECK:-1}"
PREFIX_OPUS="${CON_ENGINE_PREFIX_OPUS:-1}"
ANDROID_API=28
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

env_name() { printf '%s' "$1" | tr '-' '_'; }
env_upper() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }

ndk_bin() {
    case "$HOST_OS" in
        Darwin) echo "$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin" ;;
        *) echo "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" ;;
    esac
}

cross_clang() {
    if [ -x "$SWIFT_ORG/usr/bin/clang" ]; then echo "$SWIFT_ORG/usr/bin"; return; fi
    if command -v clang >/dev/null 2>&1 && command -v llvm-ar >/dev/null 2>&1; then
        dirname "$(command -v clang)"; return
    fi
    return 1
}

setup_target() {
    t=$1
    tn=$(env_name "$t")
    tu=$(env_upper "$t")
    case "$t" in
        *-apple-darwin)
            export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN
            ;;
        *-linux-android)
            [ -d "$NDK" ] || { say "no Android NDK at $NDK"; return 1; }
            bin=$(ndk_bin)
            arch=${t%%-*}
            export ANDROID_NDK_HOME="$NDK" ANDROID_PLATFORM="android-$ANDROID_API"
            export "CC_$tn=$bin/$arch-linux-android$ANDROID_API-clang"
            export "AR_$tn=$bin/llvm-ar"
            export "CARGO_TARGET_${tu}_LINKER=$bin/$arch-linux-android$ANDROID_API-clang"
            ;;
        x86_64-pc-windows-msvc)
            [ -d "$XWIN/crt/include" ] || { say "no Windows SDK at $XWIN (Scripts/windows-sdk.sh)"; return 1; }
            bin=$(cross_clang) || { say "no clang/llvm-ar for Windows"; return 1; }
            export "CC_$tn=$bin/clang"
            export "AR_$tn=$bin/llvm-ar"
            export "CFLAGS_$tn=--target=$t -fms-runtime-lib=dll -idirafter $XWIN/crt/include -idirafter $XWIN/sdk/include/ucrt -idirafter $XWIN/sdk/include/um -idirafter $XWIN/sdk/include/shared"
            export "CMAKE_GENERATOR_$tn=Ninja"
            for rc in "$bin/llvm-rc" /opt/homebrew/opt/llvm/bin/llvm-rc "$(command -v llvm-rc 2>/dev/null)"; do
                if [ -n "$rc" ] && [ -x "$rc" ]; then export RC="$rc"; break; fi
            done
            [ -n "${RC:-}" ] || { say "no llvm-rc (brew install llvm)"; return 1; }
            ;;
        *-unknown-linux-gnu)
            if [ "$HOST_OS" = Linux ] && [ "${t%%-*}" = "$HOST_ARCH" ]; then
                return 0
            fi
            if [ "$HOST_OS" = Linux ]; then
                say "cross-building $t on Linux needs a cross C compiler: set CC_$tn, AR_$tn"
                return 0
            fi
            arch=${t%%-*}
            [ -d "$LINUX_HEADERS/$arch" ] || { say "no Linux C headers at $LINUX_HEADERS/$arch"; return 1; }
            bin=$(cross_clang) || { say "no clang/llvm-ar for Linux"; return 1; }
            export "CC_$tn=$bin/clang"
            export "AR_$tn=$bin/llvm-ar"
            export "CFLAGS_$tn=--target=$t --sysroot=$LINUX_HEADERS/$arch -fPIC"
            ;;
    esac
    eval "CFLAGS_$tn=\"\${CFLAGS_$tn:-} -ffile-prefix-map=$HOME=~\""
    export "CFLAGS_$tn"
}

llvm_bin() {
    for d in /opt/homebrew/opt/llvm/bin "$(cross_clang 2>/dev/null || true)" "$(ndk_bin)"; do
        if [ -n "$d" ] && [ -x "$d/llvm-objcopy" ] && [ -x "$d/llvm-nm" ] && [ -x "$d/llvm-ar" ]; then
            echo "$d"
            return
        fi
    done
    return 1
}

prefix_opus() {
    t=$1
    lib=$2
    bin=$(llvm_bin) || { say "  no llvm-objcopy/llvm-nm/llvm-ar: libopus symbols not prefixed"; return 1; }
    case "$t" in *-apple-*) us=_ ;; *) us= ;; esac
    work=$(mktemp -d "${TMPDIR:-/tmp}/con-engine-prefix.XXXXXX")
    "$bin/llvm-nm" -A -g --defined-only --no-llvm-bc "$lib" 2>/dev/null \
        | grep -E '\.c\.o(bj)?: ' | awk '{print $NF}' \
        | sed -n "s/^$us\(_\{0,1\}[A-Za-z][A-Za-z0-9_]*\)\$/\1/p" | sort -u >"$work/names"
    n=$(wc -l <"$work/names" | tr -d ' ')
    if [ "$n" -lt 100 ]; then
        say "  libopus symbols not found ($n)"
        rm -rf "$work"
        return 1
    fi
    awk -v u="$us" '{print u $1 " " u "con_" $1}' "$work/names" >"$work/map"
    awk -v u="$us" '{print u $1}' "$work/names" >"$work/old"
    case "$t" in
        *-windows-*)
            "$bin/llvm-nm" -A --no-llvm-bc "$lib" 2>/dev/null \
                | awk 'NR == FNR { want[$1] = 1; next }
                       { sym = $NF; split($0, p, ": "); m = p[1]; sub(/^.*:/, "", m); if (sym in want) print m }' \
                    "$work/old" - | sort -u >"$work/members"
            dups=$("$bin/llvm-ar" t "$lib" | sort | uniq -d | grep -F -x -f "$work/members" || true)
            if [ -n "$dups" ]; then
                say "  members with the same name, cannot replace: $dups"
                rm -rf "$work"
                return 1
            fi
            mkdir "$work/m"
            (cd "$work/m" && xargs "$bin/llvm-ar" x "$lib" <"$work/members") || { rm -rf "$work"; return 1; }
            while read -r m; do
                "$bin/llvm-objcopy" --redefine-syms="$work/map" "$work/m/$m" || { rm -rf "$work"; return 1; }
            done <"$work/members"
            (cd "$work/m" && xargs "$bin/llvm-ar" r "$lib" <"$work/members") || { rm -rf "$work"; return 1; }
            ;;
        *)
            "$bin/llvm-objcopy" --redefine-syms="$work/map" "$lib" "$work/out.a" || { rm -rf "$work"; return 1; }
            mv "$work/out.a" "$lib"
            ;;
    esac
    case "$t" in
        *-apple-*) ranlib -no_warning_for_no_symbols "$lib" ;;
        *) "$bin/llvm-ar" s "$lib" ;;
    esac
    left=$("$bin/llvm-nm" -g --no-llvm-bc "$lib" 2>/dev/null | awk '{print $NF}' | grep -F -x -f "$work/old" | sort -u | head -5 || true)
    rm -rf "$work"
    if [ -n "$left" ]; then
        say "  libopus names left: $left"
        return 1
    fi
    say "  libopus: $n symbols prefixed con_"
}

lib_name() {
    case "$1" in
        *-windows-msvc) echo con_engine.lib ;;
        *) echo libcon_engine.a ;;
    esac
}

link_args() {
    lib=$1
    libs=$2
    printf '%s\n' "-L" "native=$(dirname "$lib")" "-l" "static=con_engine"
    for w in $libs; do
        printf '%s\n' "-C" "link-arg=$w"
    done
}

check_target() {
    t=$1
    lib=$2
    libs=$3
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/con-engine-check.XXXXXX")
    src="$ENGINE/tools/link_check.rs"
    exe="$tmp/link_check"
    run=""
    cfg=""
    [ "$PREFIX_OPUS" = 1 ] && cfg="--cfg own_opus"
    set -- --edition 2021 -O -D warnings --crate-name link_check --target "$t" $cfg "$src" -o
    result=0
    case "$t" in
        *-apple-darwin)
            run="selftest"
            [ "$PREFIX_OPUS" = 1 ] && run="$run opus"
            MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN rustc "$@" "$exe" $(link_args "$lib" "$libs") >"$tmp/out.txt" 2>&1 || result=1
            ;;
        *-linux-android)
            bin=$(ndk_bin); arch=${t%%-*}
            rustc "$@" "$exe" -C "linker=$bin/$arch-linux-android$ANDROID_API-clang" $(link_args "$lib" "$libs") >"$tmp/out.txt" 2>&1 || result=1
            [ "$result" = 0 ] && say "  link check linked (not run on this host)"
            ;;
        x86_64-pc-windows-msvc)
            bin=$(cross_clang)
            exe="$tmp/link_check.exe"
            rustc "$@" "$exe" -C "linker=$bin/lld-link" \
                -L "native=$XWIN/crt/lib/x86_64" -L "native=$XWIN/sdk/lib/um/x86_64" -L "native=$XWIN/sdk/lib/ucrt/x86_64" \
                $(link_args "$lib" "$libs") >"$tmp/out.txt" 2>&1 || result=1
            [ "$result" = 0 ] && say "  link check linked (link_check.exe; run it under Wine to check)"
            if [ "$result" = 0 ] && [ -n "${CON_ENGINE_KEEP_WINDOWS_CHECK:-}" ]; then
                cp "$exe" "$CON_ENGINE_KEEP_WINDOWS_CHECK"
            fi
            ;;
        *-unknown-linux-gnu)
            if [ "$HOST_OS" = Linux ] && [ "${t%%-*}" = "$HOST_ARCH" ]; then
                run="selftest"
                [ "$PREFIX_OPUS" = 1 ] && run="$run opus"
                rustc "$@" "$exe" $(link_args "$lib" "$libs") >"$tmp/out.txt" 2>&1 || result=1
            else
                say "  no link check (no $t C library on this host)"
            fi
            ;;
    esac
    if [ "$result" = 0 ] && [ -n "$run" ]; then
        "$exe" $run >"$tmp/out.txt" 2>&1 || result=1
        [ "$result" = 0 ] && say "  link check ran: $(head -1 "$tmp/out.txt"); $(grep -c . "$tmp/out.txt") lines, $(tail -1 "$tmp/out.txt")"
    fi
    [ "$result" = 0 ] || cat "$tmp/out.txt" >&2 2>/dev/null
    rm -rf "$tmp"
    return $result
}

CBINDGEN_VERSION=$(sed -n 's/^cbindgen = { version = "=\([0-9.]*\)".*/\1/p' "$ENGINE/Cargo.toml")

CBINDGEN_OWN="$ROOT/work/cbindgen-$CBINDGEN_VERSION"

cbindgen_program() {
    for c in "${CBINDGEN:-}" "$(command -v cbindgen 2>/dev/null || true)" "$HOME/.cargo/bin/cbindgen" "$CBINDGEN_OWN/bin/cbindgen"; do
        if [ -n "$c" ] && [ -x "$c" ] && [ "$("$c" --version 2>/dev/null)" = "cbindgen $CBINDGEN_VERSION" ]; then
            echo "$c"
            return
        fi
    done
    return 1
}

make_header() {
    if ! cbindgen_program >/dev/null; then
        say "installing cbindgen $CBINDGEN_VERSION into $CBINDGEN_OWN"
        env -u CARGO_TARGET_DIR cargo install cbindgen --version "$CBINDGEN_VERSION" --locked --root "$CBINDGEN_OWN" >&2 || return 1
    fi
    cb=$(cbindgen_program) || { say "no cbindgen $CBINDGEN_VERSION"; return 1; }
    mkdir -p "$OUT/include"
    tmp=$(mktemp "${TMPDIR:-/tmp}/con-engine-header.XXXXXX")
    if ! "$cb" --quiet --config "$ENGINE/cbindgen.toml" --output "$tmp" "$ENGINE/src/ffi/mod.rs"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$OUT/include/con_engine.h"
    chmod 644 "$OUT/include/con_engine.h"
    say "header: $OUT/include/con_engine.h ($(grep -c '^#define CON_[A-Z0-9_]* ' "$OUT/include/con_engine.h") constants, $(grep -c '^[a-z].*[ *]con_[a-z_]*(' "$OUT/include/con_engine.h") functions)"
}

build_target() {
    t=$1
    say "== $t"
    if ! rustup target list --installed 2>/dev/null | grep -qx "$t"; then
        rustup target add "$t" >&2
    fi
    (
        setup_target "$t" || exit 1
        stamp="$CARGO_TARGET_DIR/$t/con-engine-c-settings.txt"
        settings=$(env | grep -E "^(CC|AR|CFLAGS|CMAKE_GENERATOR)_$(env_name "$t")=|^ANDROID_|^MACOSX_DEPLOYMENT_TARGET=|^RC=" | sort)
        if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$settings" ]; then
            (cd "$ENGINE" && cargo clean --release --target "$t" -p opusic-sys >/dev/null 2>&1) || true
        fi
        log=$(mktemp "${TMPDIR:-/tmp}/con-engine-build.XXXXXX")
        if ! (cd "$ENGINE" && cargo rustc --release --lib --target "$t" -- --print native-static-libs) >"$log" 2>&1; then
            tail -40 "$log" >&2
            rm -f "$log"
            exit 1
        fi
        libs=$(sed -n 's/.*native-static-libs: //p' "$log" | tail -1)
        rm -f "$log"
        printf '%s' "$settings" >"$stamp"
        name=$(lib_name "$t")
        dest="$OUT/$t"
        mkdir -p "$dest/include"
        cp "$CARGO_TARGET_DIR/$t/release/$name" "$dest/$name"
        if [ "$PREFIX_OPUS" = 1 ]; then
            prefix_opus "$t" "$dest/$name" || exit 1
        fi
        cp "$OUT/include/con_engine.h" "$dest/include/con_engine.h"
        printf '%s\n' "$libs" >"$dest/native-libs.txt"
        size=$(du -h "$dest/$name" | cut -f1)
        say "  $dest/$name ($size)"
        say "  link with: $libs"
        if [ "$CHECK" = 1 ]; then
            check_target "$t" "$dest/$name" "$libs" || exit 1
        fi
    )
}

make_header || exit 1

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
