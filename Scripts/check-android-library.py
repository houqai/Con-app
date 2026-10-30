#!/usr/bin/env python3
import glob
import os
import re
import subprocess
import sys

library, ndk = sys.argv[1], sys.argv[2]
abi = sys.argv[3] if len(sys.argv) > 3 else 'arm64-v8a'
arch = {'arm64-v8a': 'aarch64', 'x86_64': 'x86_64'}[abi]
tools = sorted(glob.glob(ndk + '/toolchains/llvm/prebuilt/*'))[0]
sdks = os.path.expanduser('~/Library/org.swift.swiftpm/swift-sdks')

def run(*command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout

needed = [line.split('[')[1].split(']')[0] for line in run(tools + '/bin/llvm-readelf', '-d', library).splitlines() if 'NEEDED' in line]
places, runtime = {}, []
for name in needed:
    swift = [path for path in glob.glob(sdks + '/*android*/**/' + name, recursive=True) if arch in path]
    system = glob.glob('%s/sysroot/usr/lib/%s-linux-android/28/%s' % (tools, arch, name))
    places[name] = (swift + system or [None])[0]
    if swift:
        runtime.append(name)
absent = sorted(name for name, path in places.items() if path is None)
if absent:
    sys.exit('Missing libraries for Android %s: %s' % (abi, ' '.join(absent)))

defined = set()
for path in places.values():
    for line in run(tools + '/bin/llvm-nm', '-D', '--defined-only', path).splitlines():
        if line.split():
            defined.add(line.split()[-1].split('@')[0])
asked = []
for line in run(tools + '/bin/llvm-nm', '-D', '--undefined-only', library).splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[-2] not in ('w', 'v'):
        asked.append(parts[-1].split('@')[0])
missing = sorted(name for name in asked if name not in defined)
if missing:
    sys.exit('%d unresolved symbols: %s' % (len(missing), ' '.join(missing[:20])))

shared = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Android', 'CheckApp', 'java', 'app', 'con', 'check', 'Shared.java')
natives = re.findall(r'\bnative\s+[\w.\[\]]+\s+(\w+)\s*\(', open(shared, encoding='utf-8').read())
given = {line.split()[-1].split('@')[0] for line in run(tools + '/bin/llvm-nm', '-D', '--defined-only', library).splitlines() if line.split()}
wanted = ['JNI_OnLoad'] + ['Java_app_con_check_Shared_' + name for name in natives]
lacking = [name for name in wanted if name not in given]
if not natives or lacking:
    sys.exit('JNI symbols missing from the library: %s' % (' '.join(lacking) or 'no native methods found in ' + shared))
print('%s: %d imported symbols resolved across %d libraries; JNI_OnLoad and %d native methods exported' % (os.path.basename(library), len(asked), len(needed), len(natives)))
print('Swift runtime libraries to bundle: ' + ' '.join(runtime))
