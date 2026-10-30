#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RES="$(mkdir -p work/windows/resources && cd work/windows/resources && pwd)"
SIZES=(16 24 32 48 64 128 256)
for size in "${SIZES[@]}"; do sips -z $size $size Resources/Con.png --out "$RES/icon-$size.png" > /dev/null; done
python3 - "$RES" "${SIZES[@]}" <<'PY'
import struct
import sys
folder = sys.argv[1]
sizes = [int(size) for size in sys.argv[2:]]
images = [open('%s/icon-%d.png' % (folder, size), 'rb').read() for size in sizes]
header = struct.pack('<HHH', 0, 1, len(images))
offset = 6 + 16 * len(images)
entries = b''
for size, image in zip(sizes, images):
    entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(image), offset)
    offset += len(image)
open(folder + '/con.ico', 'wb').write(header + entries + b''.join(images))
PY
printf '1 ICON "con.ico"\n' > "$RES/con.rc"
(cd "$RES" && "${CON_LLVM_RC:-/opt/homebrew/opt/llvm/bin/llvm-rc}" -no-preprocess -fo con.res con.rc)
echo "$RES/con.res"
