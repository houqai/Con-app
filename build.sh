#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${CON_BUILD_DIR:-${SOLE_BUILD_DIR:-work/sole-build}}"
rm -f "$BUILD_DIR/release/Con"
swift build -c release --scratch-path "$BUILD_DIR" -Xswiftc -file-prefix-map -Xswiftc "$HOME=~" -Xcc -ffile-prefix-map="$HOME=~"
APP="Con.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift Resources/MakeIcon.swift "$BUILD_DIR/Con.iconset" Resources/Con.png
ICON_HASH="$(shasum -a 256 Resources/Con.png | cut -c 1-12)"
ICON_FILE="Con-$ICON_HASH.icns"
rm -f "$APP/Contents/Resources/Sole.icns" "$APP/Contents/Resources/Con.icns" "$APP"/Contents/Resources/Con-*.icns
iconutil -c icns "$BUILD_DIR/Con.iconset" -o "$APP/Contents/Resources/$ICON_FILE"
cp Resources/Con.png "$APP/Contents/Resources/Con.png"
rm -rf "$APP/Contents/Resources/EngineLicenses"
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$BUILD_DIR/release/Con" "$APP/Contents/MacOS/Con"
strip -S "$APP/Contents/MacOS/Con"
python3 Scripts/bundle-runtime.py "$APP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Con</string>
<key>CFBundleIdentifier</key><string>app.sole.desktop</string>
<key>CFBundleIconFile</key><string>$ICON_FILE</string>
<key>CFBundleName</key><string>Con</string>
<key>CFBundleDisplayName</key><string>Con</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>27</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>LSSupportsGameMode</key><true/>
<key>GCSupportsGameMode</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
SIGNING_DIR="${CON_SIGNING_DIR:-${SOLE_SIGNING_DIR:-work/sole-signing}}"
SIGNING_IDENTITY="${CON_SIGNING_IDENTITY:-${SOLE_SIGNING_IDENTITY:-}}"
prepare_agent() {
    local agent_path="$SIGNING_DIR/SoleCredentialAgent"
    local agent_digest
    agent_digest="$(shasum -a 256 CredentialAgent/main.swift | cut -d ' ' -f 1)"
    if [[ -x "$agent_path" && -f "$SIGNING_DIR/agent-source.sha256" ]]; then
        [[ "$(cat "$SIGNING_DIR/agent-source.sha256")" == "$agent_digest" ]] || {
            echo "Credential agent changed: preserve the existing binary and implement migration before replacing it." >&2
            exit 1
        }
    fi
    if [[ ! -x "$agent_path" ]]; then
        mkdir -p "$SIGNING_DIR"
        swiftc -O CredentialAgent/main.swift -o "$agent_path"
        if [[ -n "${2:-}" ]]; then
            codesign --sign "$1" --identifier app.sole.credentials.agent --keychain "$2" "$agent_path"
        else
            codesign --sign "$1" --identifier app.sole.credentials.agent "$agent_path"
        fi
    fi
    printf "%s\n" "$agent_digest" > "$SIGNING_DIR/agent-source.sha256"
    codesign --verify --strict -R '=identifier "app.sole.credentials.agent" and certificate leaf = H"50569e7fb68ed1ddc0b733eb2ecb3e77487d17bd"' "$agent_path"
    mkdir -p "$APP/Contents/Helpers"
    cp "$agent_path" "$APP/Contents/Helpers/SoleCredentialAgent"
}
if [[ -n "$SIGNING_IDENTITY" ]]; then
    prepare_agent "$SIGNING_IDENTITY"
    for dependency in "$APP"/Contents/Frameworks/*.dylib; do
        [[ -f "$dependency" ]] && codesign --force --sign "$SIGNING_IDENTITY" "$dependency"
    done
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
else
    [[ -f "$SIGNING_DIR/identity.sha1" ]] || { echo "Missing local signing identity; configure CON_SIGNING_IDENTITY." >&2; exit 1; }
    SIGNING_DIR="$(cd "$SIGNING_DIR" && pwd)"
    security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$SIGNING_DIR/signing.keychain-db"
    SIGNING_IDENTITY="$(cat "$SIGNING_DIR/identity.sha1")"
    prepare_agent "$SIGNING_IDENTITY" "$SIGNING_DIR/signing.keychain-db"
    for dependency in "$APP"/Contents/Frameworks/*.dylib; do
        [[ -f "$dependency" ]] && codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_DIR/signing.keychain-db" "$dependency"
    done
    codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_DIR/signing.keychain-db" "$APP"
fi
codesign --verify --deep --strict "$APP"
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
