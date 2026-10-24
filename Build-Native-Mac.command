#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_root="$PWD"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "이 프로젝트는 Mac과 Xcode에서 빌드해야 합니다."
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "전체 Xcode가 필요합니다. App Store에서 Xcode를 설치하고 최초 실행을 완료해주세요."
  echo "Command Line Tools만 설치한 환경은 Xcode 생성기를 사용할 수 없습니다."
  exit 1
fi
# CMake.app이나 Homebrew로 설치한 cmake도 찾기
for cmake_dir in /Applications/CMake.app/Contents/bin "$HOME/Applications/CMake.app/Contents/bin" /opt/homebrew/bin /usr/local/bin; do
  if [[ -x "$cmake_dir/cmake" ]] && ! command -v cmake >/dev/null 2>&1; then export PATH="$cmake_dir:$PATH"; fi
done
if ! command -v cmake >/dev/null 2>&1; then
  echo "CMake 3.28 이상이 필요합니다. https://cmake.org/download/"
  echo "Homebrew를 사용한다면: brew install cmake"
  exit 1
fi
if [[ ! -f vendor/obs-studio/libobs/obs.h ]]; then
  echo "공식 OBS 소스가 없습니다. bash scripts/Fetch-OBS.command 를 먼저 실행하세요."
  exit 1
fi
mkdir -p logs dist
build_dir="$task_root/build-macos"
obs_dir="$task_root/vendor/obs-studio"
echo "Church OBS 독립 엔진 빌드를 시작합니다."
echo "첫 실행에는 공식 OBS 빌드 의존성을 다운로드하므로 시간이 걸립니다."
python3 "$task_root/scripts/prepare_obs.py" 2>&1 | tee "$task_root/logs/source-preparation.log"
python3 "$task_root/scripts/Verify-Source.py"
(
  cd "$obs_dir"
  cmake --preset macos -B "$build_dir" \
    -DENABLE_FRONTEND=OFF -DENABLE_PLUGINS=OFF -DENABLE_SCRIPTING=OFF \
    -DENABLE_BROWSER=OFF -DENABLE_TEST_INPUT=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DOBS_VERSION_OVERRIDE=32.2.2 -DOBS_CODESIGN_IDENTITY=- \
    -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DWORSHIP_SOURCE_DIR="$task_root" \
    -UCMAKE_PROJECT_obs-studio_INCLUDE
  cmake --build "$build_dir" --config Release --target churchobs --parallel 4
) 2>&1 | tee "$task_root/logs/build.log"
app_path="$build_dir/worship/Release/ChurchOBS.app"
if [[ ! -d "$app_path" ]]; then
  echo "예상 경로에 앱이 없습니다: $app_path"
  exit 1
fi
/usr/bin/ditto "$app_path" "$task_root/dist/ChurchOBS.app"
# 언어별 문자열 (한국어·English): 서명 전에 번들에 넣는다
python3 "$task_root/scripts/make_strings.py" >/dev/null
for lproj in "$task_root"/app/resources/*.lproj; do
  rm -rf "$task_root/dist/ChurchOBS.app/Contents/Resources/$(basename "$lproj")"
  /usr/bin/ditto "$lproj" "$task_root/dist/ChurchOBS.app/Contents/Resources/$(basename "$lproj")"
done
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Church OBS Dev"'; then
  export WS_SIGN_IDENTITY="Church OBS Dev"
  echo "서명: Church OBS Dev 인증서 — 다시 빌드해도 화면 녹화·카메라 권한이 유지됩니다"
else
  echo "서명: 임시 서명 — 빌드할 때마다 화면 녹화 권한을 다시 줘야 합니다 (한 번만: bash Setup-Signing.command)"
fi
python3 "$task_root/scripts/fix_runtime_deps.py" "$task_root/dist/ChurchOBS.app"
bash "$task_root/scripts/Check-Bundle.command" "$task_root/dist/ChurchOBS.app"
echo "빌드 완료: $task_root/dist/ChurchOBS.app"
echo "다음 확인: bash Run-Engine-Test.command"
