#!/usr/bin/env python3
"""Add a checked, idempotent end-of-directory frontend hook to OBS sources."""
import hashlib
import json
from pathlib import Path

HOOK = b'''
# WORSHIP_FRONTEND_BEGIN
if(DEFINED WORSHIP_SOURCE_DIR)
  add_subdirectory("${WORSHIP_SOURCE_DIR}/app" "${CMAKE_BINARY_DIR}/worship")
endif()
# WORSHIP_FRONTEND_END
'''

def original_source(data: bytes) -> bytes:
    if data.endswith(HOOK):
        return data[:-len(HOOK)]
    if b'# WORSHIP_FRONTEND_BEGIN' in data:
        raise ValueError('Existing Worship frontend hook differs from the known integration block')
    return data

# Checked, reversible changes to the pinned OBS snapshot. The app requires macOS 14+.
EXTERNAL_OLD = b"AVCaptureDeviceTypeExternalUnknown"
EXTERNAL_NEW = b"AVCaptureDeviceTypeExternal /* CHURCHOBS_MACOS14_EXTERNAL */"
WINDOW_OLD = b"    return CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, wc->window.window_id,\n                                   wc->image_option);"
WINDOW_NEW = (b'#pragma clang diagnostic push\n#pragma clang diagnostic ignored "-Wdeprecated-declarations"\n'
              + WINDOW_OLD + b'\n#pragma clang diagnostic pop')
CAPTURE_PATCHES = {
    'plugins/mac-avcapture/plugin-properties.m': (EXTERNAL_OLD, EXTERNAL_NEW, 2),
    'plugins/mac-avcapture/legacy/av-capture.mm': (EXTERNAL_OLD, EXTERNAL_NEW, 1),
    'plugins/mac-capture/mac-window-capture.m': (WINDOW_OLD, WINDOW_NEW, 1),
}

def upstream_source(name: str, data: bytes) -> bytes:
    if name == 'CMakeLists.txt':
        return original_source(data)
    if name in CAPTURE_PATCHES:
        old, new, _ = CAPTURE_PATCHES[name]
        return data.replace(new, old)
    return data

def prepare_capture(root: Path) -> bool:
    manifest = json.loads((root / 'source-manifest.json').read_text())
    pending = []
    for name, (old, new, count) in CAPTURE_PATCHES.items():
        path = root / 'vendor/obs-studio' / name
        current = path.read_bytes()
        original = upstream_source(name, current)
        if hashlib.sha256(original).hexdigest() != manifest['sha256'][name]:
            raise ValueError(f'OBS source differs from the pinned snapshot; preserving local edits: {name}')
        if original.count(old) != count:
            raise ValueError(f'Unexpected API occurrence count: {name}')
        desired = original.replace(old, new)
        pending.append((path, current, desired))
    # Check every file before writing any file; reruns are idempotent.
    changed = False
    for path, current, desired in pending:
        if current != desired:
            path.write_bytes(desired)
            changed = True
        if path.read_bytes() != desired:
            raise ValueError(f'Capture compatibility patch was not applied: {path.name}')
    print('PASS build 18 source preparation: current/legacy camera use AVCaptureDeviceTypeExternal; legacy window call locally guarded')
    return changed

def prepare(root: Path) -> bool:
    path = root / 'vendor/obs-studio/CMakeLists.txt'
    current = path.read_bytes()
    original = original_source(current)
    manifest = json.loads((root / 'source-manifest.json').read_text())
    expected = manifest['sha256']['CMakeLists.txt']
    if hashlib.sha256(original).hexdigest() != expected:
        raise ValueError('OBS CMakeLists.txt differs from the pinned source; refusing to overwrite local edits')
    if current == original + HOOK:
        return False
    path.write_bytes(original + HOOK)
    return True

if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    prepare_capture(root)
    changed = prepare(root)
    print('OBS frontend hook prepared' if changed else 'OBS frontend hook already prepared')
