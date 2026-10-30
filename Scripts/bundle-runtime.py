#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
executable = app / 'Contents/MacOS/Con'
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
licenses = app / 'Contents/Resources/DependencyLicenses'
shutil.rmtree(licenses, ignore_errors=True)
licenses.mkdir(parents=True, exist_ok=True)

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def dependencies(path):
    lines = command('otool', '-L', str(path)).splitlines()[1:]
    return [line.strip().split(' (compatibility version')[0] for line in lines]

copied = {}
pending = [executable]
while pending:
    binary = pending.pop()
    for dependency in dependencies(binary):
        if not dependency.startswith('/opt/homebrew/'):
            continue
        source = pathlib.Path(dependency).resolve(strict=True)
        target = frameworks / source.name
        if source.name in copied and copied[source.name] != source:
            raise RuntimeError(f'Conflicting libraries: {source.name}')
        if source.name not in copied:
            copied[source.name] = source
            shutil.copy2(source, target)
            target.chmod(0o755)
            subprocess.check_call(['install_name_tool', '-id', '@rpath/' + target.name, str(target)])
            pending.append(target)
            if '/Cellar/' in str(source):
                parts = source.parts
                index = parts.index('Cellar')
                root = pathlib.Path(*parts[:index + 3])
                for pattern in ['LICENSE*', 'COPYING*', 'COPYRIGHT*', 'Copyright*']:
                    for notice in root.glob(pattern):
                        if notice.is_file():
                            folder = licenses / parts[index + 1]
                            folder.mkdir(exist_ok=True)
                            shutil.copy2(notice, folder / notice.name)
        prefix = '@executable_path/../Frameworks/' if binary == executable else '@loader_path/'
        subprocess.check_call(['install_name_tool', '-change', dependency, prefix + target.name, str(binary)])

for stale in frameworks.glob('*.dylib'):
    if stale.name not in copied:
        stale.unlink()

for binary in [executable, *frameworks.glob('*.dylib')]:
    if any(value.startswith('/opt/homebrew/') for value in dependencies(binary)):
        raise RuntimeError(f'Unbundled dependency: {binary.name}')
for folder in [licenses, frameworks]:
    if not any(folder.iterdir()):
        folder.rmdir()
print(f'Bundled {len(copied)} runtime libraries')
