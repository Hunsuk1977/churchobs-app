#!/bin/bash
# Church OBS 배포 파일 만들기: 빌드된 앱 → 서명(Hardened Runtime) → .dmg → Apple 공증 → 스테이플
# 결과: dist/ChurchOBS-<버전>.dmg  (누구나 경고 없이 열 수 있음)
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
mkdir -p logs dist
exec > >(tee logs/release.log) 2>&1
echo "== Church OBS 배포 파일 만들기 · $(date) =="
[[ -f signing.env ]] || { echo "❌ 먼저 Setup-Signing.command 를 실행하세요."; read -r -p "Enter…" _; exit 1; }
source signing.env
app_src="build-macos/worship/Release/ChurchOBS.app"
[[ -d "$app_src" ]] || { echo "❌ 빌드된 앱이 없습니다. Build-Native-Mac.command 를 먼저 실행하세요."; read -r -p "Enter…" _; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_src/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app_src/Contents/Info.plist")
work="dist/release-work"; rm -rf "$work"; mkdir -p "$work/stage"
app="$work/stage/Church OBS.app"
ditto "$app_src" "$app"
xattr -cr "$app"

sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
echo "1/5 안쪽 부품 서명"
find "$app/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -print0 | while IFS= read -r -d '' f; do sign "$f"; done
for f in "$app/Contents/Frameworks/"*.framework; do sign "$f"; done
for f in "$app/Contents/PlugIns/"*.plugin; do
  find "$f/Contents/MacOS" -type f -perm +111 -print0 2>/dev/null | while IFS= read -r -d '' bin; do sign "$bin"; done
  sign "$f"
done
sign "$app/Contents/MacOS/obs-ffmpeg-mux"
echo "2/5 앱 서명"
sign --entitlements app/resources/ChurchOBS.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

echo "3/5 .dmg 만들기"
ln -s /Applications "$work/stage/Applications"
dmg="dist/ChurchOBS-$version-$build.dmg"
rm -f "$dmg"
hdiutil create -volname "Church OBS $version" -srcfolder "$work/stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"

echo "4/5 Apple 공증 (보통 2~10분)"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$work/notary.txt"
if ! grep -q "status: Accepted" "$work/notary.txt"; then
  id=$(grep -m1 "id:" "$work/notary.txt" | awk '{print $2}')
  echo "❌ 공증이 거절되었습니다. 이유:"
  [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" | tee logs/notary-log.json
  read -r -p "Enter…" _; exit 1
fi
echo "5/5 스테이플·확인"
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
echo
echo "✅ 완성: $root/$dmg"
open -R "$dmg"
read -r -p "Enter를 누르면 닫힙니다…" _
