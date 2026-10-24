#!/bin/bash
# Church OBS 서명 준비 (처음 한 번)
#  1) Developer ID Application 인증서가 이 Mac 키체인에 있는지 확인
#  2) 공증(notarization)용 로그인 정보를 키체인에 저장 (암호는 이 창에만 입력, 파일에 남지 않음)
set -uo pipefail
cd "$(dirname "$0")"
echo "== Church OBS 서명 준비 =="
echo
find_identity() { security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/'; }
identity=$(find_identity)

# 진단 1: 인증서는 있는데 "신뢰할 수 없음" → Apple 중간 인증서(Developer ID G2) 설치
if [[ -z "$identity" ]] && security find-identity -p codesigning | grep -q "Developer ID Application"; then
  echo "인증서는 있지만 신뢰 확인이 안 됩니다. Apple 중간 인증서를 설치합니다…"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
    && security import "$tmp/DeveloperIDG2CA.cer" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1
  identity=$(find_identity)
fi

# 진단 2: 웹에서 받은 인증서(.cer)를 이 스크립트가 만든 키와 합치기
keydir="$HOME/Library/Application Support/ChurchOBS/signing"
cer=$(ls -t "$HOME/Downloads/"developerID_application*.cer 2>/dev/null | head -1 || true)
if [[ -z "$identity" && -f "$keydir/churchobs.key" && -n "$cer" ]]; then
  echo "내려받은 인증서를 키와 합쳐 키체인에 넣습니다: $(basename "$cer")"
  pass=$(openssl rand -hex 12)
  openssl x509 -inform DER -in "$cer" -out "$keydir/cert.pem"
  openssl pkcs12 -export -inkey "$keydir/churchobs.key" -in "$keydir/cert.pem" -out "$keydir/churchobs.p12" -passout "pass:$pass" -name "Church OBS Developer ID"
  security import "$keydir/churchobs.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign -T /usr/bin/productsign
  rm -f "$keydir/churchobs.p12"
  curl -fsSL -o "$keydir/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
    && security import "$keydir/DeveloperIDG2CA.cer" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
  identity=$(find_identity)
fi

if [[ -z "$identity" ]]; then
  echo "❌ 이 Mac 키체인에서 쓸 수 있는 'Developer ID Application' 인증서를 찾지 못했습니다."
  echo
  echo "Xcode의 Manage Certificates로 만들면 '클라우드 관리' 인증서가 되어 키가 이 Mac에 없을 수 있습니다."
  echo "그래서 웹에서 직접 만드는 방법으로 진행합니다. (키는 이 Mac에만 만들어집니다)"
  echo
  mkdir -p "$keydir"; chmod 700 "$keydir"
  if [[ ! -f "$keydir/churchobs.key" ]]; then
    openssl genrsa -out "$keydir/churchobs.key" 2048 2>/dev/null
    chmod 600 "$keydir/churchobs.key"
  fi
  read -r -p "Apple 개발자 계정 이메일: " email
  csr="$HOME/Desktop/ChurchOBS-DeveloperID.certSigningRequest"
  openssl req -new -key "$keydir/churchobs.key" -out "$csr" -subj "/emailAddress=$email/CN=Church OBS/C=US"
  echo
  echo "✅ 바탕화면에 요청 파일을 만들었습니다: ChurchOBS-DeveloperID.certSigningRequest"
  echo
  echo "이제 브라우저에서 (곧 열립니다):"
  echo "  1. + 를 누르고 'Developer ID Application' 을 고른 뒤 Continue"
  echo "  2. Profile Type 이 나오면 'G2 Sub-CA (Xcode 11.4.1 or later)' 그대로 두고 Continue"
  echo "  3. Choose File 로 바탕화면의 요청 파일을 올리고 Continue"
  echo "  4. Download 를 누르면 '다운로드' 폴더에 developerID_application.cer 이 생깁니다"
  echo "  5. 이 파일(Setup-Signing.command)을 다시 더블클릭하면 자동으로 키체인에 넣습니다"
  open "https://developer.apple.com/account/resources/certificates/add"
  echo
  echo "참고: 지금 이 Mac에 있는 서명 인증서 목록"
  security find-identity -p codesigning | sed 's/^/   /'
  read -r -p "Enter를 누르면 닫힙니다…" _
  exit 1
fi
team=$(echo "$identity" | sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/')
echo "✅ 인증서: $identity"
echo "   팀 ID:  $team"
cat > signing.env <<ENV
# Setup-Signing.command 가 만든 파일 (비밀 정보 없음)
SIGN_IDENTITY="$identity"
TEAM_ID="$team"
NOTARY_PROFILE="churchobs-notary"
ENV
echo
if xcrun notarytool history --keychain-profile churchobs-notary >/dev/null 2>&1; then
  echo "✅ 공증 로그인 정보가 이미 저장되어 있습니다 (churchobs-notary)."
else
  echo "공증용 로그인 정보를 저장합니다."
  echo "먼저 https://account.apple.com 에서 '앱 암호'를 하나 만드세요:"
  echo "  로그인 › 로그인 및 보안 › 앱 암호 › + (이름 예: Church OBS notary)"
  echo
  read -r -p "Apple 개발자 계정 이메일: " email
  echo "이제 방금 만든 앱 암호(xxxx-xxxx-xxxx-xxxx)를 물으면 붙여 넣으세요. 화면에는 보이지 않습니다."
  if xcrun notarytool store-credentials churchobs-notary --apple-id "$email" --team-id "$team"; then
    echo "✅ 저장했습니다. 암호는 이 Mac 키체인에만 있습니다."
  else
    echo "❌ 저장하지 못했습니다. 이메일·앱 암호를 확인하고 다시 실행하세요."
    read -r -p "Enter를 누르면 닫힙니다…" _; exit 1
  fi
fi
echo
echo "준비 끝. 이제 Make-Release-DMG.command 로 배포 파일을 만들 수 있습니다."
read -r -p "Enter를 누르면 닫힙니다…" _
