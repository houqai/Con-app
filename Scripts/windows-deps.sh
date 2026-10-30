#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/windows-env.sh
DOWN="$W/downloads"
mkdir -p "$DOWN"

fetch() {
  local file="$1" url="$2" sha="$3"
  [[ -f "$DOWN/$file" ]] || { curl -fL --retry 3 -sS -o "$DOWN/$file.part" "$url"; mv "$DOWN/$file.part" "$DOWN/$file"; }
  echo "$sha  $DOWN/$file" | shasum -a 256 -c - > /dev/null || { mv -f "$DOWN/$file" "$DOWN/$file.bad"; echo "Checksum mismatch for $file: moved to $DOWN/$file.bad. Run again to download it again." >&2; exit 1; }
}
fetch SDL2-devel-2.32.10-VC.zip https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-devel-2.32.10-VC.zip \
  af347939395a58b365846aaea27391e69f9ec9d4dd650d6ac40802159b418a6e
fetch ffmpeg-n8.1.3-14-g330caae0c1-win64-lgpl-shared-8.1.zip https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-07-13-07/ffmpeg-n8.1.3-14-g330caae0c1-win64-lgpl-shared-8.1.zip \
  30fdaaeb116730fdd6432c2663af0e9ecdf1d6cc387ac085cc1faf8494942510
fetch GTK4_Gvsbuild_2026.8.0_x64.zip https://github.com/wingtk/gvsbuild/releases/download/2026.8.0/GTK4_Gvsbuild_2026.8.0_x64.zip \
  1f95a92d037f5292da05e6ab1037032ff21ddb7b20d4ac8e83e3674c864c07b0
fetch Inter-4.1.zip https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip \
  9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e
fetch microsoft.web.webview2.1.0.4258.31.nupkg https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4258.31/microsoft.web.webview2.1.0.4258.31.nupkg \
  56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9

rm -rf "$DEPS" "$W/unpacked"
mkdir -p "$DEPS/include" "$DEPS/lib" "$DEPS/bin" "$DEPS/fonts" "$DEPS/licenses" "$W/unpacked"
U="$W/unpacked"
unzip -q "$DOWN/SDL2-devel-2.32.10-VC.zip" -d "$U/sdl2"
unzip -q "$DOWN/ffmpeg-n8.1.3-14-g330caae0c1-win64-lgpl-shared-8.1.zip" -d "$U/ffmpeg"
unzip -q "$DOWN/GTK4_Gvsbuild_2026.8.0_x64.zip" 'bin/*.dll' 'include/*' 'lib/*.lib' 'lib/glib-2.0/include/*' 'share/licenses/*' 'share/doc/*' -d "$U/gtk" 2>/dev/null || true
unzip -q -j "$DOWN/Inter-4.1.zip" extras/ttf/Inter-Regular.ttf extras/ttf/Inter-Medium.ttf extras/ttf/Inter-SemiBold.ttf extras/ttf/Inter-Bold.ttf -d "$DEPS/fonts"
unzip -q -p "$DOWN/Inter-4.1.zip" LICENSE.txt > "$DEPS/licenses/Inter.txt"
unzip -q -p "$DOWN/microsoft.web.webview2.1.0.4258.31.nupkg" LICENSE.txt > "$DEPS/licenses/WebView2.txt"
unzip -q -p "$DOWN/microsoft.web.webview2.1.0.4258.31.nupkg" NOTICE.txt > "$DEPS/licenses/WebView2-NOTICE.txt"

mkdir -p "$DEPS/include/SDL2"
cp "$U"/sdl2/SDL2-*/include/*.h "$DEPS/include/SDL2/"
cp "$U"/sdl2/SDL2-*/lib/x64/SDL2.lib "$DEPS/lib/"
cp "$U"/sdl2/SDL2-*/lib/x64/SDL2.dll "$DEPS/bin/"
cp "$U"/sdl2/SDL2-*/LICENSE.txt "$DEPS/licenses/SDL2.txt" 2>/dev/null || cp "$U"/sdl2/SDL2-*/COPYING.txt "$DEPS/licenses/SDL2.txt"
F="$(echo "$U"/ffmpeg/ffmpeg-*)"
cp -R "$F/include/." "$DEPS/include/"
cp "$F"/lib/{avcodec,avutil,swscale}.lib "$DEPS/lib/"
cp "$F"/bin/avcodec-*.dll "$F"/bin/avutil-*.dll "$F"/bin/swscale-*.dll "$F"/bin/swresample-*.dll "$DEPS/bin/" 2>/dev/null || cp "$F"/bin/avcodec-*.dll "$F"/bin/avutil-*.dll "$F"/bin/swscale-*.dll "$DEPS/bin/"
cp "$F/LICENSE.txt" "$DEPS/licenses/FFmpeg.txt"
G="$U/gtk"
for folder in cairo pango-1.0 glib-2.0 harfbuzz fribidi freetype2 fontconfig pixman-1 libpng16; do
  [[ -d "$G/include/$folder" ]] && cp -R "$G/include/$folder" "$DEPS/include/"
done
cp "$G/lib/glib-2.0/include/glibconfig.h" "$DEPS/include/glib-2.0/"
for library in cairo pango-1.0 pangocairo-1.0 gobject-2.0 glib-2.0; do cp "$G/lib/$library.lib" "$DEPS/lib/"; done

python3 - "$TOOLS/llvm-objdump" "$G" "$DEPS" <<'PY'
import os, re, shutil, subprocess, sys
objdump, gtk, deps = sys.argv[1:]
source, target = os.path.join(gtk, 'bin'), os.path.join(deps, 'bin')
available = {name.lower(): name for name in os.listdir(source) if name.lower().endswith('.dll')}
wanted = ['cairo-2.dll', 'pango-1.0-0.dll', 'pangocairo-1.0-0.dll', 'gobject-2.0-0.dll', 'glib-2.0-0.dll']
taken = set()
while wanted:
    name = wanted.pop().lower()
    if name in taken or name not in available: continue
    taken.add(name)
    shutil.copy(os.path.join(source, available[name]), target)
    imports = subprocess.run([objdump, '-p', os.path.join(source, available[name])], capture_output=True, text=True).stdout
    wanted += [m.lower() for m in re.findall(r'DLL Name: (\S+)', imports)]
def plain(name):
    name = name.lower()
    return re.sub(r'[-_.\d]+$', '', name[3:] if name.startswith('lib') else name)
family = {'gobject': ('glib',), 'gio': ('glib',), 'gmodule': ('glib',), 'pangocairo': ('pango',), 'pangoft': ('pango',),
          'pangowin': ('pango',), 'intl': ('gettext', 'proxy-libintl'), 'iconv': ('win-iconv',), 'zlib': ('zlib-ng',)}
projects = {}
for top in ['doc', 'licenses']:
    folder = os.path.join(gtk, 'share', top)
    for project in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if any(files for _, _, files in os.walk(os.path.join(folder, project))):
            projects.setdefault(plain(project), []).append(os.path.join(folder, project))
own = {'freetype': 'Resources/Licenses/FreeType-FTL.txt'}
unlicensed = []
for name in sorted(taken):
    key = plain(name[:-4])
    found = [path for project in (key,) + family.get(key, ()) for path in projects.get(project, [])]
    if not found and key in own:
        os.makedirs(os.path.join(deps, 'licenses', 'gtk', key), exist_ok=True)
        shutil.copy(own[key], os.path.join(deps, 'licenses', 'gtk', key))
        continue
    if not found: unlicensed.append(name)
    for path in found: shutil.copytree(path, os.path.join(deps, 'licenses', 'gtk', os.path.basename(path)), dirs_exist_ok=True)
print('Cairo and Pango: %d DLLs' % len(taken))
if unlicensed: sys.exit('No licence in the GTK archive (share/doc, share/licenses) for: ' + ', '.join(unlicensed))
PY
rm -rf "$U"

mkdir -p "$DEPS/pkgconfig"
pc() {
  printf 'Name: %s\nDescription: %s for Windows x64 (Scripts/windows-deps.sh)\nVersion: 0\nCflags: %s\nLibs: -L%s %s\n' "$1" "$1" "$2" "$DEPS/lib" "$3" > "$DEPS/pkgconfig/$1.pc"
}
pc sdl2 "-I$DEPS/include/SDL2 -DSDL_MAIN_HANDLED" "-lSDL2"
pc pangocairo "-I$DEPS/include/cairo -I$DEPS/include/pango-1.0 -I$DEPS/include/glib-2.0 -I$DEPS/include/harfbuzz -I$DEPS/include/fribidi -I$DEPS/include/freetype2" \
   "-lpangocairo-1.0 -lpango-1.0 -lcairo -lgobject-2.0 -lglib-2.0"
echo "Libraries for Windows: $DEPS"
