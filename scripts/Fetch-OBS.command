#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
obs_path="$PWD/vendor/obs-studio"
expected_commit="ba2f32bdf791005443988a4955e963663e16b1ed"
if [[ -e "$obs_path" ]]; then
  echo "vendor/obs-studio가 이미 있습니다. 기존 파일을 덮어쓰지 않습니다."
  exit 0
fi
mkdir -p vendor
git clone --depth 1 --branch 32.2.2 --recurse-submodules --shallow-submodules \
  https://github.com/obsproject/obs-studio.git "$obs_path"
actual_commit="$(git -C "$obs_path" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "소스 커밋이 고정된 버전과 다릅니다. 빌드를 중단합니다."
  exit 1
fi
echo "공식 OBS 32.2.2 소스와 하위 모듈을 확보했습니다."
