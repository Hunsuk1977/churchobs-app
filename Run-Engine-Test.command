#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_path="$PWD/dist/ChurchOBS.app"
if [[ ! -d "$app_path" ]]; then
  echo "먼저 bash Build-Native-Mac.command 를 실행하세요."
  exit 1
fi
mkdir -p logs
test_path="$PWD/dist/engine-smoke-$(date +%Y%m%d-%H%M%S).mkv"
bash scripts/Check-Bundle.command "$app_path"
"$app_path/Contents/MacOS/ChurchOBS" --smoke-test "$test_path" 2>&1 | tee "$PWD/logs/engine-smoke.log"
echo "PASS engine smoke test: process exited normally"
"$app_path/Contents/MacOS/ChurchOBS" --ui-smoke-test 2>&1 | tee "$PWD/logs/ui-smoke.log"
echo "PASS native UI smoke test: process exited normally"
echo "엔진·GPU·필터·녹화·준비/진행 UI 테스트가 끝났습니다. 파일: $test_path"
