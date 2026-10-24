# YouTube 연결 · 개발 버전 0.4.0

이 버전은 실제 Google OAuth / YouTube Live API / OBS RTMPS 송출을 연결하는 구현입니다. Linux 환경에서는 Google 계정 승인·macOS 키체인·Mac 빌드·실제 YouTube 방송을 실행하지 못했습니다. 아직 검증된 상용 앱이 아닙니다. 아래 등록을 완료하고 Mac에서 시험해야 합니다.

## 현재 사용할 화면

1. 영상 엔진 시작 → 카메라 연결 → 마이크 연결.
2. 5개 장면 중 하나를 선택. 처음에는 방송 대기 화면이며 카메라는 찬양·설교 장면에서 보입니다.
3. YouTube 연결 → 브라우저에서 Google 승인.
4. 예약 예배를 선택하거나 ‘새 예배…’에서 제목·공개 범위·아동용 여부 지정.
5. 화면·마이크 확인 → 방송 시작. YouTube가 영상 수신을 확인한 뒤 live로 전환합니다.
6. 장면 버튼으로 전환 → 방송 종료.

신규 예배의 기본 공개 범위는 **일부 공개**입니다. 공개 방송은 명시적으로 선택하세요. 새 예배 만들기는 예약 방송을 생성하며 방송 시작 버튼이 별도로 있습니다. 실행한 테스트나 앱 설치가 실제 방송을 자동 시작하지 않습니다.

| 장면 | 현재 구현 |
| --- | --- |
| 방송 대기 | 안내 문구 카드 |
| 찬양 | 카메라 + 하단 가사 문구 |
| 설교 | 자연 보정 카메라 + 하단 제목 |
| 말씀·자료 | 본문 문구 또는 PNG/JPEG 이미지 한 장 |
| 예배 종료 | 마침 안내 카드 |

‘문구·가사 편집’과 ‘자료 이미지 선택’은 적용 즉시 현재 영상에 반영합니다. 선택한 자료 이미지는 본문 문구보다 우선합니다. ‘이미지 해제’를 누르면 다시 본문 문구를 표시합니다. PPT 원본 불러오기·다중 슬라이드 넘김·가사 큐 목록·찬양 동영상 재생은 이 버전에 포함하지 않습니다. 모든 장면에서 마이크는 계속 유지하며 음소거는 별도 버튼으로 조작합니다. 장면 이름과 배치는 현재 고정입니다.

## 개발자가 최초 한 번 할 Google 설정

각 교회 운영자에게 이 과정을 반복시키는 제품 구조가 아닙니다. 개발용으로 앱 소유자가 등록하며, 배포 앱에는 승인된 클라이언트 구성을 포함하도록 후속 작업합니다.

1. https://console.cloud.google.com/ 에서 앱 소유자의 프로젝트 생성/선택.
2. API Library에서 **YouTube Data API v3** 활성화.
3. Google Auth Platform에서 앱 이름·지원 이메일·대상(Audience) 구성. 테스트 중에는 승인할 Google 계정을 테스트 사용자로 추가.
4. Data Access에 `https://www.googleapis.com/auth/youtube.force-ssl` 권한 추가.
5. Clients → Create client → **Desktop app** 선택 → JSON 다운로드. Web application용 JSON은 사용할 수 없습니다.
6. Church OBS의 **YouTube 연결**을 처음 누를 때 해당 JSON 선택.
7. 기본 브라우저에서 방송 채널의 계정으로 승인. 방송 권한이 있는 YouTube 채널을 사용합니다.

비밀번호나 토큰을 채팅에 붙여넣을 필요는 없습니다. 로그인은 Google 페이지에서 진행합니다. 이 개발 버전은 Mac의 Python 3를 API 보조 프로세스로 사용합니다. 빌드 도구를 설치한 현재 개발 Mac을 대상으로 하며, 일반 사용자 배포에서는 이 런타임 의존성 제거/번들링이 남아 있습니다.

OAuth는 PKCE S256, 랜덤 state, 127.0.0.1의 임시 포트 콜백을 사용합니다. 토큰은 macOS 키체인에 보관하고 보조 프로세스에는 익명 파이프로 전달합니다. 스트림 키는 준비 작업의 메모리 안에서만 전달하며 앱 화면이나 작업 인자·설정 파일에 저장하지 않습니다. Google 클라이언트 구성은 앱 지원 폴더에 저장합니다. 개발용 Desktop 클라이언트 설정은 비밀을 보장할 수 있는 서버 자격 증명이 아닙니다.

진행 중인 방송 ID는 로컬에 저장하여 앱 재시작 시 서버 상태를 조회합니다. 방송 중 권한이 만료되면 ‘YouTube 재인증’으로 같은 채널 계정을 다시 승인할 수 있습니다. 앱이 꺼져도 서버 방송이 자동 종료됐다고 가정하지 않습니다.

계정을 바꾸거나 `invalid_grant`가 표시되면 상단 **Church OBS → YouTube 연결 해제** 후 다시 연결하세요. 이 메뉴는 Mac의 키체인 로그인 정보를 삭제합니다. Google 측 앱 권한을 철회하려면 Google 계정의 연결된 앱 관리에서도 제거합니다.

공개 구독 제품으로 배포하기 전에는 Google 앱 검증, 개인정보 처리 안내, API 정책·할당량·배포 서명·공증과 실제 장시간 송출 검증을 완료해야 합니다. 테스트용 OAuth에는 재승인 제약이 있을 수 있습니다.

## 오류와 방송 상태

- `liveStreamingNotEnabled` / `livePermissionBlocked`: 해당 채널의 라이브 사용 가능 상태를 YouTube Studio에서 확인합니다.
- `access_denied`: 로그인 승인이 취소됐거나 테스트 사용자 설정을 확인해야 합니다.
- `invalid_grant`: 연결 해제 후 다시 승인합니다.
- `quotaExceeded`: Google 프로젝트의 API 할당량을 확인합니다.
- 기존 예약 방송의 자동 시작/자동 종료가 켜져 있으면 먼저 Studio에서 끄거나 앱에서 새 예배를 만듭니다. 예상치 못한 자동 시작·종료를 피하기 위한 현재 구현 제약입니다.
- 시작 요청 후 응답이 끊기면 시작 요청을 무작정 재전송하지 않습니다. **방송 상태 확인**을 누르며, 필요하면 메뉴의 **YouTube Studio 열기**로 실제 상태를 확인합니다.
- 종료는 서버가 complete임을 확인한 후 송출을 멈춥니다. API 종료 실패 시 송출을 자동으로 끊지 않습니다. 갑작스러운 앱/컴퓨터 종료는 별개이므로 Studio에서 상태를 확인합니다.
- 네트워크 송출이 끊겨도 YouTube 방송이 끝났다고 표시하지 않습니다. 종료 확인 전에는 앱 종료를 막습니다. 현재 버전은 중단 후 자동 재연결 3회가 모두 실패하면 수동 Studio 확인이 필요합니다.

앱의 미리보기는 현재 송출 장면과 같습니다. 화면 비교와 얼굴 위치 진단 표시는 방송 시작 시 해제합니다. 로컬 녹화는 별도 버튼이며 방송 시작이 녹화를 자동 시작하지 않습니다.

## 검증 범위

로컬: OAuth PKCE 표준 벡터, 실제 localhost HTTP 콜백과 잘못된 state 거부/승인 취소, 토큰 갱신, 방송 목록 필터/페이지, 신규 방송 자동 시작 금지, 스트림 생성·바인딩, 이미 사용 중인 스트림 거부, active 확인 후 live 전환, 불확실한 변경 요청 재전송 금지, 종료 상태 확인, 오류 문자열의 비밀 제외 — 14개 테스트. Google 네트워크 경계는 모의 처리했습니다.

Mac 자동 검사에 추가: 실제 RTMPS 서비스·출력 생성(네트워크 연결 없음), 5개 장면 GPU 출력 픽셀 변화. 이 새 검사는 Linux에서는 실행할 수 없으며 **실행 대기**입니다. 일반 스모크 테스트는 실제 YouTube에 로그인하거나 방송하지 않습니다.

미검증: 새 Objective-C++/Apple SDK 컴파일·링크, Keychain 승인, 실제 Google OAuth 승인·채널 선택·API 응답, 실제 RTMPS 연결, 소리·영상 동기화, 장시간 예배, 장면 문자 방향·크기·잘림과 실제 기기 성능.

## 공식 문서

- Desktop OAuth / PKCE: https://developers.google.com/identity/protocols/oauth2/native-app
- 방송 생성: https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/insert
- 방송·스트림 연결: https://developers.google.com/youtube/v3/live/guides/implementation/broadcasts-and-streams
- 방송 상태 전환: https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/transition
- RTMPS 주소: https://developers.google.com/youtube/v3/live/docs/liveStreams
- 채널 라이브 시작: https://support.google.com/youtube/answer/2474026

공식 문서 확인: 2026-10-18 America/New_York.
