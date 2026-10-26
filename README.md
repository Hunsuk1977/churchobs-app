# Church OBS

**교회를 위한 간편 YouTube 방송 소프트웨어 · Simple YouTube streaming for churches** — https://churchobs.app

Church OBS는 OBS Studio의 영상 엔진(libobs)을 그대로 쓰면서, 준비 → 장면 → 자료 → 진행 네 단계로 예배 방송을 쉽게 하도록 만든 macOS 앱입니다.
Church OBS is a macOS app built on the OBS Studio engine (libobs) that streams worship services to YouTube in four steps: prepare → scenes → materials → live.

> 이 저장소는 GPL 의무에 따라 공개하는 **앱 소스**입니다. 계정 서버는 포함하지 않습니다.
> This repository is the **app source**, published under the GPL. The account server is not included.

## 기능 · Features
- 카메라·마이크·화면/창 캡처(PowerPoint·Keynote·ProPresenter), 사진·영상·음악, 유튜브 영상, 글자 오브젝트, 그래픽
- 장면 편집(끌어서 배치·크기·회전·크롭), 진행 화면(미리보기→송출 전환, 컷·페이드·슬라이드)
- YouTube 방송 만들기·시작·종료, 1080p 하드웨어 인코딩(VideoToolbox)
- 출력 창(프로젝터)에 송출과 같은 화면 또는 다른 장면
- 영상 소리를 방송/현장 스피커로 나눠 보내기
- 자료 단계: WORDaLIVE 스튜디오(슬라이드·실시간 번역 자막) · 다른 프로그램 창 가져오기 · 내장 PDF/사진 넘김기 중 선택

## 빌드 · Build (macOS 14+, Apple Silicon)
Requirements: full **Xcode** (not just Command Line Tools), **CMake 3.28+**, git.

```bash
bash scripts/Fetch-OBS.command     # official OBS Studio 32.2.2 source (pinned commit) into vendor/
./Build-Native-Mac.command         # builds build-macos/worship/Release/ChurchOBS.app
./Run-With-Log.command             # runs it, logging to logs/app.log
```

YouTube 연결에는 Google Cloud의 **Desktop app** OAuth 클라이언트가 필요합니다. `app/resources/youtube-oauth.json` 으로 두면 앱에 포함되고, 없으면 앱에서 JSON을 불러옵니다. 자세한 내용: `docs/YOUTUBE-SETUP.md`.
YouTube needs a Google Cloud **Desktop app** OAuth client. Put it at `app/resources/youtube-oauth.json` to bundle it, or import the JSON in the app. See `docs/YOUTUBE-SETUP.md`.

Signed, notarized builds: `Setup-Signing.command` (once) then `Make-Release-DMG.command` (requires an Apple Developer ID).

## 라이선스 · License
GPL-2.0-or-later. See `LICENSE` and `NOTICE.md`.
