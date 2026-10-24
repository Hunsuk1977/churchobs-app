#!/bin/bash
set -euo pipefail
app_path="${1:?앱 경로를 지정하세요}"
for relative in \
  "Contents/MacOS/ChurchOBS" \
  "Contents/MacOS/obs-ffmpeg-mux" \
  "Contents/Frameworks/libobs.framework/libobs" \
  "Contents/Frameworks/libobs-opengl.dylib" \
  "Contents/Resources/skin-soften.effect" \
  "Contents/Resources/shape-mask.effect" \
  "Contents/Resources/camera-look.effect" \
  "Contents/Resources/youtube_client.py" \
  "Contents/PlugIns/obs-outputs.plugin/Contents/MacOS/obs-outputs" \
  "Contents/PlugIns/rtmp-services.plugin/Contents/MacOS/rtmp-services" \
  "Contents/PlugIns/obs-transitions.plugin/Contents/MacOS/obs-transitions" \
  "Contents/PlugIns/image-source.plugin/Contents/MacOS/image-source" \
  "Contents/Resources/face-reference.bgra" \
  "Contents/PlugIns/mac-avcapture.plugin/Contents/MacOS/mac-avcapture" \
  "Contents/PlugIns/mac-capture.plugin/Contents/MacOS/mac-capture" \
  "Contents/PlugIns/obs-filters.plugin/Contents/MacOS/obs-filters" \
  "Contents/PlugIns/obs-x264.plugin/Contents/MacOS/obs-x264" \
  "Contents/PlugIns/obs-ffmpeg.plugin/Contents/MacOS/obs-ffmpeg"; do
  if [[ ! -f "$app_path/$relative" ]]; then
    echo "번들 파일 누락: $relative"
    exit 1
  fi
done
binary="$app_path/Contents/MacOS/ChurchOBS"
if /usr/bin/otool -L "$binary" | /usr/bin/grep -q '/Applications/OBS.app'; then
  echo "외부 OBS 앱 의존성이 발견됐습니다."
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
python3 "$(dirname "$0")/fix_runtime_deps.py" --check-only "$app_path"
echo "PASS 번들 리소스와 로컬 서명 확인"
