#!/usr/bin/env python3
import pathlib
import re
import subprocess
import sys

if len(sys.argv) != 3:
    sys.exit('Usage: check-older-macos.py <app> <sdk>')
app = pathlib.Path(sys.argv[1]).resolve()
sdk = pathlib.Path(sys.argv[2])
if not sdk.is_dir():
    sys.exit(f'No SDK at {sdk}')
older = tuple(int(part) for part in re.search(r'MacOSX(\d+(?:\.\d+)?)\.sdk', sdk.name).group(1).split('.'))

def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout

binaries = [app / 'Contents/MacOS/Con']
binaries += sorted((app / 'Contents/Helpers').glob('*')) + sorted((app / 'Contents/Frameworks').glob('*.dylib'))

def built_for(binary):
    found = re.search(r'minos (\S+)', run('vtool', '-show-build', str(binary)))
    return found.group(1) if found else '?'

def newer(version):
    try:
        return tuple(int(part) for part in version.split('.'))[:len(older)] > older
    except ValueError:
        return True

offers = {binary.name: {line.split()[-1] for line in run('nm', '-gU', str(binary)).splitlines() if line.split()} for binary in binaries}

def carried(binary):
    names = set()
    for line in run('otool', '-L', str(binary)).splitlines()[1:]:
        linked = pathlib.PurePath(line.strip().split(' (compatibility')[0]).name
        names |= offers.get(linked, set())
    return names

token = re.compile(r"[^\s,\[\]'\"]+")
offered = set()
lists = 0
for folder in [sdk / 'usr/lib', sdk / 'System/Library/Frameworks']:
    for tbd in folder.rglob('*.tbd'):
        offered.update(token.findall(tbd.read_text(errors='replace')))
        lists += 1

def listed(name):
    for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_', '_OBJC_EHTYPE_$_', '_OBJC_IVAR_$_'):
        if name.startswith(prefix):
            return name[len(prefix):] in offered
    return name in offered

missing = {}
asked = 0
checked = []
versions = {binary.name: built_for(binary) for binary in binaries}
for binary in binaries:
    if not newer(versions[binary.name]):
        continue
    checked.append(binary.name)
    own = carried(binary)
    for line in run('nm', '-m', '-u', str(binary)).splitlines():
        if not line.split() or 'weak external' in line:
            continue
        name = next((word for word in line.split() if word.startswith('_')), '')
        if not name or name in own:
            continue
        asked += 1
        if not listed(name):
            missing.setdefault(binary.name, []).append(name)

print('Built for: ' + ', '.join(f'{name} {version}' for name, version in versions.items()))
print(f'{len(checked)} binaries target macOS newer than {".".join(map(str, older))}: {asked} imported symbols checked against {lists} .tbd files of {sdk.name}')
if missing:
    for name, names in missing.items():
        print(f'Missing from {sdk.name} (used by {name}): ' + ' '.join(sorted(names)[:40]))
    sys.exit(1)
print(f'All imported symbols exist in {sdk.name}.')
