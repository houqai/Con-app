#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
android_abi arm64-v8a
export JAVA_HOME="${JAVA_HOME:-$WORK/android-sdk/jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
TOOLS="$(ls -d "$SDK"/build-tools/* | tail -1)"
PLATFORM="$(ls -d "$SDK"/platforms/android-* | tail -1)/android.jar"
LIBRARY="$WORK/android/$ABI/libConShared.so"
[[ -x "$JAVA_HOME/bin/javac" ]] || { echo "No JDK at $JAVA_HOME. See docs/BUILD.md." >&2; exit 2; }
[[ -x "$TOOLS/aapt2" && -f "$PLATFORM" ]] || { echo "No Android build tools or platform in $SDK." >&2; exit 2; }
[[ -f "$LIBRARY" ]] || { echo "No shared library: run Scripts/build-shared-android.sh first." >&2; exit 2; }
android_runtime
OUT="$WORK/android/$ABI/check-app"
rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/stage/lib/$ABI"
javac -source 17 -target 17 -Xlint:-options -classpath "$PLATFORM" -d "$OUT/classes" $(find Android/CheckApp/java -name '*.java')
"$TOOLS/d8" --lib "$PLATFORM" --min-api 28 --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
mkdir -p "$OUT/res/mipmap-xxxhdpi" "$OUT/assets"
sips -s format png -z 192 192 Resources/Con.png --out "$OUT/res/mipmap-xxxhdpi/icon.png" > /dev/null
sips -s format png -z 256 256 Resources/Con.png --out "$OUT/assets/Con.png" > /dev/null
cp THIRD-PARTY-NOTICES.md "$OUT/assets/"
mkdir -p "$OUT/assets/licenses" && cp Resources/Licenses/Swift.txt Resources/Licenses/Swift-Foundation.txt Resources/Licenses/ICU.txt "$OUT/assets/licenses/"
"$TOOLS/aapt2" compile -o "$OUT/resources.zip" "$OUT/res/mipmap-xxxhdpi/icon.png"
"$TOOLS/aapt2" link -o "$OUT/unsigned.apk" --manifest Android/CheckApp/AndroidManifest.xml -I "$PLATFORM" --min-sdk-version 28 --target-sdk-version 35 \
  -R "$OUT/resources.zip" -A "$OUT/assets"
cp "$LIBRARY" "$OUT/stage/lib/$ABI/"
for library in "$RUNTIME"/*.so; do
  case "$(basename "$library")" in libXCTest.so|libTesting.so|lib_Testing*) ;; *) cp "$library" "$OUT/stage/lib/$ABI/" ;; esac
done
cp "$LIBCXX" "$OUT/stage/lib/$ABI/"
cp "$OUT/dex/classes.dex" "$OUT/stage/"
(cd "$OUT/stage" && zip -q -r ../unsigned.apk classes.dex lib)
"$TOOLS/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KEY="$WORK/android/check-app.keystore"
[[ -f "$KEY" ]] || keytool -genkeypair -keystore "$KEY" -storepass android -keypass android -alias check -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Con check app" > /dev/null 2>&1
"$TOOLS/apksigner" sign --ks "$KEY" --ks-pass pass:android --key-pass pass:android --out "$WORK/android/$ABI/con-check.apk" "$OUT/aligned.apk"
"$TOOLS/apksigner" verify "$WORK/android/$ABI/con-check.apk"
echo "The check app is built: $WORK/android/$ABI/con-check.apk ($(du -h "$WORK/android/$ABI/con-check.apk" | cut -f1 | tr -d ' '))"
