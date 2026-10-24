#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/churchobs-check.XXXXXX")"
trap 'python3 - "$check_dir" <<'"'"'PY'"'"'
import shutil,sys
shutil.rmtree(sys.argv[1])
PY' EXIT
cc -std=c11 -Wall -Wextra -Werror tests/face_frame_test.c app/filters/face_frame.c -o "$check_dir/face-frame"
cc -std=c11 -Wall -Wextra -Werror tests/face_geometry_test.c app/filters/face_geometry.c -lm -o "$check_dir/face-geometry"
cc -std=c11 -Wall -Wextra -Werror tests/studio_timing_test.c -lm -o "$check_dir/studio-timing"
cc -std=c11 -Wall -Wextra -Werror tests/studio_layout_test.c -lm -o "$check_dir/studio-layout"
cc -std=c11 -Wall -Wextra -Werror tests/graph_geometry_test.c -lm -o "$check_dir/graph-geometry"
"$check_dir/graph-geometry"
"$check_dir/studio-layout"
"$check_dir/face-frame"
"$check_dir/face-geometry"
"$check_dir/studio-timing"
python3 scripts/Check-App-Source.py

python3 -m unittest discover -s tests -p test_youtube_client.py

python3 -m unittest discover -s tests -p test_stage_card_update.py

python3 -m unittest discover -s tests -p test_probe_subscription.py

if command -v xcrun >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then
  xcrun swiftc -frontend -parse app/swift/*.swift
  echo "PASS Swift source parsing (full Mac SDK compilation follows in the build)"
fi
