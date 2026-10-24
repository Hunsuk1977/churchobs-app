#!/usr/bin/env python3
"""Verify included upstream source bytes against the snapshot manifest."""
import hashlib
import json
from pathlib import Path
import sys
from prepare_obs import upstream_source

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'source-manifest.json').read_text())
failed = []
for name, expected in manifest['sha256'].items():
    path = root / 'vendor' / 'obs-studio' / name
    data = path.read_bytes() if path.is_file() else b''
    data = upstream_source(name, data)
    if not path.is_file() or hashlib.sha256(data).hexdigest() != expected:
        failed.append(name)
if failed:
    print('FAIL source snapshot:', *failed, sep='\n')
    sys.exit(1)
print(f"PASS {len(manifest['sha256'])} upstream source files match {manifest['commit']}")
