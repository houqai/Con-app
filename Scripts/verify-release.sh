#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="Con.app"
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
contents = app / 'Contents'
info = plistlib.loads((contents / 'Info.plist').read_bytes())
assert info['CFBundleName'] == 'Con'
assert info['CFBundleExecutable'] == 'Con'
assert info['LSApplicationCategoryType'] == 'public.app-category.games' and info['LSSupportsGameMode'] is True
for file in ['MacOS/Con', 'Resources/Con.png', 'Resources/' + info['CFBundleIconFile'],
             'Resources/THIRD-PARTY-NOTICES.md', 'Helpers/SoleCredentialAgent']:
    assert (contents / file).is_file(), f'Missing {file}'
for binary in [contents/'MacOS/Con', *contents.glob('Frameworks/*.dylib')]:
    output = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    assert '/opt/homebrew/' not in output, f'External dependency: {binary.name}'
print(f"Bundle verified: Con {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
PY
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = "26.0" ] || { echo "LSMinimumSystemVersion is not 26.0"; exit 1; }
OLDER_SDK="${CON_OLDEST_SDK:-${SOLE_OLDEST_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}}"
if [ -d "$OLDER_SDK" ]; then python3 Scripts/check-older-macos.py "$APP" "$OLDER_SDK"; else echo "macOS 26 SDK not found: system symbol check skipped."; fi
echo "Local bundle checks passed. Distribution signing and notarization are separate."
