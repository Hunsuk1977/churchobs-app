#!/usr/bin/env python3
"""Close an OBS app's Mach-O dependency graph, then locally sign inside-out.

Only copies exact dependency filenames from the pinned OBS prebuilt libraries.
Never copies arbitrary libraries from the host or an installed OBS app.
"""
import argparse
from collections import deque
from dataclasses import dataclass
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

MAGICS = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
SYSTEM_PREFIXES = ('/System/Library/', '/usr/lib/', '/Library/Apple/System/Library/')
LOAD_COMMANDS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}

@dataclass(frozen=True)
class Dependency:
    name: str
    weak: bool = False

@dataclass
class ImageInfo:
    dependencies: list
    rpaths: list

def run_tool(arguments):
    result = subprocess.run([str(x) for x in arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(str(x) for x in arguments) + '\n' + result.stderr.strip())
    return result.stdout

def parse_load_commands(text):
    dependencies, rpaths = [], []
    command = ''
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('cmd '):
            command = line[4:]
        elif command in LOAD_COMMANDS and line.startswith('name '):
            name = re.sub(r' \(offset \d+\)$', '', line[5:])
            entry = Dependency(name, command == 'LC_LOAD_WEAK_DYLIB')
            if entry not in dependencies:
                dependencies.append(entry)
        elif command == 'LC_RPATH' and line.startswith('path '):
            path = re.sub(r' \(offset \d+\)$', '', line[5:])
            if path not in rpaths:
                rpaths.append(path)
    return ImageInfo(dependencies, rpaths)

def read_image(path):
    return parse_load_commands(run_tool(['/usr/bin/otool', '-l', path]))

def is_macho(path):
    if not path.is_file():
        return False
    with path.open('rb') as file:
        return file.read(4) in MAGICS

def within(path, parent):
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False

def bundled_images(app):
    return sorted({path.resolve() for path in app.rglob('*') if is_macho(path)})

def is_system(dependency):
    # Swift OS runtime images can exist only in the dyld shared cache.
    return dependency.startswith(SYSTEM_PREFIXES) or dependency.startswith('@rpath/libswift')

class DependencyClosure:
    def __init__(self, app, library_root, repair=False):
        self.app = Path(app).resolve()
        self.frameworks = self.app / 'Contents/Frameworks'
        self.executable_dir = self.app / 'Contents/MacOS'
        self.library_root = Path(library_root).resolve()
        self.repair = repair
        self.copied = []
        self.rewrites = []
        self.origins = {}
        self.library_index = {}
        if self.library_root.is_dir():
            for path in sorted(self.library_root.rglob('*.dylib')):
                self.library_index.setdefault(path.name, []).append(path)

    def expand(self, value, loader):
        value = value.replace('@loader_path', str(loader.parent))
        value = value.replace('@executable_path', str(self.executable_dir))
        return Path(value) if not value.startswith('@') else None

    def existing(self, dependency, loader, info):
        candidates = []
        if dependency.startswith('@rpath/'):
            tail = dependency[len('@rpath/'):]
            candidates.append(self.frameworks / tail)
            for rpath in info.rpaths:
                base = self.expand(rpath, loader)
                if base is not None:
                    candidates.append(base / tail)
        else:
            path = self.expand(dependency, loader)
            if path is not None:
                candidates.append(path)
        for candidate in candidates:
            if candidate.is_file() and within(candidate, self.app):
                return candidate.resolve()
        return None

    def source_for(self, dependency):
        name = Path(dependency).name
        if not name.endswith('.dylib') or '.framework/' in dependency:
            raise RuntimeError('Missing framework or unsupported dependency: ' + dependency)
        candidates = self.library_index.get(name, [])
        if not candidates:
            raise RuntimeError('Pinned OBS dependency not found: ' + name + '\nSearched: ' + str(self.library_root))
        real = {path.resolve() for path in candidates}
        if len(real) != 1:
            raise RuntimeError('Ambiguous dependency filename: ' + name)
        source = candidates[0]
        if not within(source, self.library_root):
            raise RuntimeError('Dependency symlink escapes the pinned dependency directory: ' + str(source))
        if not is_macho(source):
            raise RuntimeError('Dependency is not a Mach-O image: ' + str(source))
        return source

    def close(self):
        if not self.app.is_dir():
            raise RuntimeError('Built app not found: ' + str(self.app))
        queue = deque(bundled_images(self.app))
        if not queue:
            raise RuntimeError('No Mach-O images found in app')
        seen, missing = set(), []
        while queue:
            loader = queue.popleft()
            if loader in seen:
                continue
            if not within(loader, self.app):
                raise RuntimeError('Bundle image escapes app: ' + str(loader))
            seen.add(loader)
            info = read_image(loader)
            if loader.parent == self.executable_dir:
                runtime_path = '@executable_path/../Frameworks'
                if runtime_path not in info.rpaths:
                    if not self.repair:
                        missing.append(f'{loader.relative_to(self.app)} -> missing bundle LC_RPATH')
                    else:
                        run_tool(['/usr/bin/install_name_tool', '-add_rpath', runtime_path, loader])
                        info.rpaths.append(runtime_path)
            for dep in info.dependencies:
                if is_system(dep.name):
                    continue
                existing = self.existing(dep.name, loader, info)
                if existing:
                    queue.append(existing)
                    continue
                # An absolute build-machine reference may point to a library
                # already embedded under its filename. Rewrite, never overwrite.
                embedded = self.frameworks / Path(dep.name).name
                if dep.name.startswith('/') and embedded.is_file() and within(embedded, self.app):
                    if not self.repair:
                        if not dep.weak:
                            missing.append(f'{loader.relative_to(self.app)} -> nonportable {dep.name}')
                        continue
                    new_name = '@rpath/' + embedded.name
                    run_tool(['/usr/bin/install_name_tool', '-change', dep.name, new_name, loader])
                    self.rewrites.append((str(loader), dep.name, new_name))
                    queue.append(embedded.resolve())
                    continue
                if not self.repair:
                    if not dep.weak:
                        missing.append(f'{loader.relative_to(self.app)} -> {dep.name}')
                    continue
                try:
                    source = self.source_for(dep.name)
                except RuntimeError:
                    if dep.weak:
                        continue
                    raise
                destination = self.origins.get(source.resolve())
                if destination is None:
                    destination = self.frameworks / Path(dep.name).name
                    self.frameworks.mkdir(parents=True, exist_ok=True)
                    if destination.exists():
                        raise RuntimeError('Refusing to overwrite existing library: ' + str(destination))
                    shutil.copy2(source, destination, follow_symlinks=True)
                    destination.chmod(destination.stat().st_mode | 0o200)
                    run_tool(['/usr/bin/install_name_tool', '-id', '@rpath/' + destination.name, destination])
                    self.origins[source.resolve()] = destination
                    self.copied.append(destination.name)
                    print('Added runtime dependency:', destination.name)
                new_name = '@rpath/' + destination.name
                if dep.name != new_name:
                    run_tool(['/usr/bin/install_name_tool', '-change', dep.name, new_name, loader])
                    self.rewrites.append((str(loader), dep.name, new_name))
                queue.append(destination)
        if missing:
            raise RuntimeError('Unresolved app dependencies:\n' + '\n'.join(missing))
        return len(seen)

def sign_bundle(app):
    images = bundled_images(app)
    for image in images:
        run_tool(['/usr/bin/codesign', '--force', '--sign', os.environ.get('WS_SIGN_IDENTITY', '-'), image])
    containers = {p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.framework', '.plugin', '.app')}
    for bundle in sorted(containers, key=lambda p: len(p.parts), reverse=True):
        run_tool(['/usr/bin/codesign', '--force', '--sign', os.environ.get('WS_SIGN_IDENTITY', '-'), bundle])
    run_tool(['/usr/bin/codesign', '--force', '--sign', os.environ.get('WS_SIGN_IDENTITY', '-'), app])
    run_tool(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--library-root', type=Path)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('Run this repair on the Mac where the app was built')
    root = Path(__file__).resolve().parent.parent
    libraries = args.library_root or root / 'vendor/obs-studio/.deps/obs-deps-2026-07-15-universal/lib'
    closure = DependencyClosure(args.app, libraries, repair=not args.check_only)
    count = closure.close()
    if not args.check_only:
        # Re-check the resulting graph independently before re-signing the app.
        count = DependencyClosure(args.app, libraries).close()
        sign_bundle(args.app.resolve())
    print(f'PASS runtime dependency closure: {count} Mach-O images, {len(closure.copied)} libraries added')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError) as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(1)
