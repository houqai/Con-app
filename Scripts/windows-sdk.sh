#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/windows-env.sh
SWIFT_WINDOWS_SHA256=76169a85bcba82854a0cd8f9655ffb74b3758d60c35a245457510095f2823c03
if [[ ! -d "$W/xwin/sdk" ]]; then
  "$HOME/.cargo/bin/xwin" --accept-license --cache-dir "$W/.xwin-cache" --arch x86_64 splat --output "$W/xwin"
fi
SDK="$W/swift-sdk/LocalApp/Programs/Swift/Platforms/$SWIFT_VERSION/Windows.platform/Developer/SDKs/Windows.sdk"
if [[ ! -d "$SDK" ]]; then
  [[ -f "$W/swift-windows.exe" ]] || { curl -fL -o "$W/swift-windows.exe.part" "https://download.swift.org/swift-$SWIFT_VERSION-release/windows10/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-windows10.exe"; mv "$W/swift-windows.exe.part" "$W/swift-windows.exe"; }
  if [[ "$(shasum -a 256 "$W/swift-windows.exe" | cut -d ' ' -f 1)" != "$SWIFT_WINDOWS_SHA256" ]]; then
    echo "SHA-256 mismatch for swift-windows.exe (expected Swift $SWIFT_VERSION from swift.org): removed, run again." >&2
    rm -f "$W/swift-windows.exe"
    exit 1
  fi
  offset=$(python3 - "$W/swift-windows.exe" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read(8 * 1024 * 1024)
first = data.find(b'MSCF\x00\x00\x00\x00')
print(data.find(b'MSCF\x00\x00\x00\x00', first + 8))
PY
)
  tail -c +$((offset + 1)) "$W/swift-windows.exe" > "$W/container.cab"
  mkdir -p "$W/msi" && rm -f "$W/msi"/*
  python3 - "$W" <<'PY'
import re, subprocess, sys
w = sys.argv[1]
manifest = subprocess.run(['7zz', 'x', '-so', w + '/swift-windows.exe', '0'], capture_output=True).stdout.decode('utf-8', 'replace')
wanted = {'windows.msi', 'windows.cab', 'sdk.windows.x64.cab', 'sdk.windows.arm64.cab', 'sdk.windows.x86.cab', 'rtl.amd64.msi', 'rtl.amd64.cab'}
for name, source in re.findall(r'FilePath="([^"]+)"[^>]*SourcePath="(a\d+)"', manifest):
    if name in wanted:
        subprocess.run(['7zz', 'e', '-y', '-o' + w + '/msi', w + '/container.cab', source], check=True, capture_output=True)
        subprocess.run(['mv', w + '/msi/' + source, w + '/msi/' + name], check=True)
PY
  rm -f "$W/container.cab"
  msiextract -C "$W/swift-sdk" "$W/msi/windows.msi" > /dev/null
  msiextract -C "$W/swift-rtl" "$W/msi/rtl.amd64.msi" > /dev/null
fi
X="$W/xwin"
if [[ ! -f "$X/sdk/include/ucrt/corecrt_math.h" ]]; then
  mv "$X/sdk/include/ucrt/math.h" "$X/sdk/include/ucrt/corecrt_math.h"
  printf '#pragma once\n#include <corecrt_math.h>\n' > "$X/sdk/include/ucrt/math.h"
fi
if ! grep -q '#define _UCRT_RESTORE_CLANG_WARNINGS' "$X/crt/include/threads.h"; then
  python3 - "$X/crt/include/threads.h" <<'PY'
import sys
path = sys.argv[1]; text = open(path).read()
text = text.replace('#pragma once\n', '#pragma once\n#ifndef _UCRT_DISABLE_CLANG_WARNINGS\n#define _UCRT_DISABLE_CLANG_WARNINGS\n#define _UCRT_RESTORE_CLANG_WARNINGS\n#endif\n', 1)
open(path, 'w').write(text)
PY
fi
cp "$SDK/usr/share/ucrt.modulemap" "$X/sdk/include/ucrt/module.modulemap"
cp "$SDK/usr/share/winsdk_um.modulemap" "$X/sdk/include/um/module.modulemap"
cp "$SDK/usr/share/winsdk_shared.modulemap" "$X/sdk/include/shared/module.modulemap"
cp "$SDK/usr/share/vcruntime.modulemap" "$X/crt/include/module.modulemap"
cp "$SDK/usr/share/vcruntime.apinotes" "$X/crt/include/vcruntime.apinotes"
python3 - "$X" <<'PY'
import os, re, sys
x = sys.argv[1]
for path in ['sdk/include/ucrt/module.modulemap', 'sdk/include/um/module.modulemap', 'sdk/include/shared/module.modulemap', 'crt/include/module.modulemap']:
    path = os.path.join(x, path); folder = os.path.dirname(path)
    lines = open(path).read().split('\n')
    kept = [l for l in lines if not (m := re.match(r'\s*(?:textual\s+)?header\s+"([^"]+)"', l)) or os.path.exists(os.path.join(folder, m.group(1)))]
    open(path, 'w').write('\n'.join(kept))
PY
B="$W/sdks/con-windows.artifactbundle"
XCTEST="$SDK/../../Library/XCTest-$SWIFT_VERSION/usr/lib/swift/windows"
TESTING="$SDK/../../Library/Testing-$SWIFT_VERSION/usr/lib/swift/windows"
mkdir -p "$B/x86_64-unknown-windows-msvc"
cat > "$B/info.json" <<JSON
{ "schemaVersion": "1.0", "artifacts": { "con-windows": { "type": "swiftSDK", "version": "$SWIFT_VERSION",
  "variants": [ { "path": "x86_64-unknown-windows-msvc", "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"] } ] } } }
JSON
cat > "$B/x86_64-unknown-windows-msvc/swift-sdk.json" <<JSON
{ "schemaVersion": "4.0", "targetTriples": { "x86_64-unknown-windows-msvc": {
  "sdkRootPath": "$SDK", "swiftResourcesPath": "$SDK/usr/lib/swift", "swiftStaticResourcesPath": "$SDK/usr/lib/swift_static",
  "includeSearchPaths": ["$X/crt/include", "$X/sdk/include/ucrt", "$X/sdk/include/um", "$X/sdk/include/shared", "$X/sdk/include/winrt"],
  "librarySearchPaths": ["$X/crt/lib/x86_64", "$X/sdk/lib/um/x86_64", "$X/sdk/lib/ucrt/x86_64", "$SDK/usr/lib/swift/windows/x86_64", "$XCTEST/x86_64", "$TESTING/x86_64"],
  "toolsetPaths": ["toolset.json"] } } }
JSON
cat > "$B/x86_64-unknown-windows-msvc/toolset.json" <<JSON
{ "schemaVersion": "1.0",
  "cCompiler": { "extraCLIOptions": ["-fms-compatibility"] },
  "swiftCompiler": { "extraCLIOptions": ["-use-ld=lld", "-I", "$XCTEST", "-I", "$TESTING"] },
  "linker": { "path": "lld-link" } }
JSON
echo "Swift SDK for Windows x86_64: $B"
