#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_binary="$PWD/dist/ChurchOBS.app/Contents/MacOS/ChurchOBS"
if [[ ! -x "$app_binary" ]]; then
  echo "빌드된 앱이 없습니다. 먼저 bash Build-Native-Mac.command 를 실행하세요."
  exit 1
fi
mkdir -p logs
"$app_binary" 2>&1 | tee "$PWD/logs/app.log"
