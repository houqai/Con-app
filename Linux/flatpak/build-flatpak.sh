#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mkdir -p work && cd work && pwd)"
ARCH="$(uname -m)"
command -v flatpak-builder > /dev/null || { echo "flatpak-builder not found (Ubuntu: sudo apt install flatpak-builder)." >&2; exit 2; }
flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak --user install -y --noninteractive flathub org.gnome.Platform//48 org.gnome.Sdk//48 org.freedesktop.Sdk.Extension.swift6//24.08 org.freedesktop.Sdk.Extension.rust-stable//24.08
OUT="$WORK/flatpak"
mkdir -p "$OUT"
flatpak-builder --user --force-clean --repo="$OUT/repo" --state-dir="$OUT/state" "$OUT/build" Linux/flatpak/app.sole.Con.yml
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo "$OUT/repo" "$OUT/app.sole.Con-$ARCH.flatpak" app.sole.Con
echo "Flatpak bundle for $ARCH: $OUT/app.sole.Con-$ARCH.flatpak"
