// SceneModels.swift
// churchobs — 장면(Scene) / 소스(Source) 데이터 모델
//
// 핵심 구조 (OBS와 동일한 2단 구조):
//   Source     = 장치·창·URL 그 자체. 여러 장면이 공유한다. (카메라를 장면마다 다시 열지 않음)
//   SceneItem  = 어떤 Source를 이 장면의 어디에, 어떤 크기로, 보이게/숨기게 둘지.
//   ShowScene  = SceneItem 배열(뒤 → 앞 순서) + 이 장면으로 들어올 때의 전환 효과.
//
// 좌표는 모두 0...1 정규화(캔버스 16:9 기준). 출력 해상도가 바뀌어도 레이아웃이 유지된다.

import Foundation
import CoreGraphics
import AppKit

// MARK: - Source

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case window, screen, browser, camera, audio, text, media, youtube, graphic, captions, slides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window:  L("윈도우 캡처")
        case .screen: L("화면 캡처")
        case .browser: L("브라우저")
        case .camera:  L("카메라")
        case .audio:   L("오디오 캡처")
        case .text: L("문구·가사")
        case .media: L("사진·반복 영상")
        case .youtube: L("유튜브 영상")
        case .graphic: L("그래픽")
        case .captions: L("WORDaLIVE 자막")
        case .slides: L("WORDaLIVE 슬라이드")
        }
    }

    var subtitle: String {
        switch self {
        case .window:  L("PowerPoint·Keynote·ProPresenter 슬라이드 창 등 앱 창 하나")
        case .screen: L("프로젝터·두 번째 모니터 화면을 통째로")
        case .browser: L("웹 페이지·자막 오버레이 (투명 배경)")
        case .camera:  L("웹캠, 캡처보드, EOS Webcam 등")
        case .audio:   L("준비 화면에서 연결한 마이크·믹서 입력")
        case .text: L("안내 문구·찬양 가사·이름 자막")
        case .media: L("로컬 사진·동영상·음악 파일")
        case .youtube: L("유튜브 주소로 영상 재생 · 반복 가능 (인터넷 필요)")
        case .graphic: L("아이콘 팩 (Lucide·Material·Phosphor 등)")
        case .captions: L("실시간 번역 자막 (준비 화면에서 WORDaLIVE 연결)")
        case .slides: L("WORDaLIVE 스튜디오에서 송출 중인 슬라이드")
        }
    }

    /// SF Symbol 이름
    var symbol: String {
        switch self {
        case .window:  "macwindow"
        case .screen: "display"
        case .browser: "globe"
        case .camera:  "video"
        case .audio:   "mic"
        case .text: "text.alignleft"
        case .media: "photo.on.rectangle"
        case .youtube: "play.rectangle.fill"
        case .graphic: "star.square.on.square"
        case .captions: "captions.bubble"
        case .slides: "rectangle.on.rectangle.angled"
        }
    }

    /// 화면에 그려지는 소스인가 (오디오는 믹서에만 나옴)
    var isVisual: Bool { self != .audio }
}

enum SourceConfig: Codable, Hashable {
    case text(value: String, opaque: Bool)
    case media(path: String, loop: Bool, audioOnly: Bool)
    /// 아이콘 팩 그래픽: icon = "lucide:church", color = "FFFFFF", path = 만들어 둔 PNG
    case graphic(icon: String, color: String, path: String)
    /// WORDaLIVE 번역 자막 띠 (1920×360). lines = 한 번에 보일 문장 수
    case captions(showSource: Bool, background: Bool, fontSize: Int, lines: Int)
    /// WORDaLIVE 스튜디오의 현재 슬라이드 (그림은 준비 화면의 WORDaLIVE 연결이 받아 온다)
    case slides
    /// 유튜브 영상: url = 붙여 넣은 주소 (영상 ID·시작 시각을 여기서 읽는다)
    case youtube(url: String, loop: Bool)
    /// ScreenCaptureKit 의 SCWindow 를 다시 찾기 위한 정보. windowID는 재실행 시 바뀌므로 bundleID+title로 재매칭.
    case window(bundleID: String?, windowTitle: String?, cropChrome: Bool, captureAppAudio: Bool)
    /// 모니터 하나를 통째로. displayID = CGDisplay UUID 문자열, name = 보여 줄 이름
    case screen(displayID: String?, name: String?)
    case browser(url: URL?, transparentBackground: Bool, width: Int, height: Int)
    /// AVCaptureDevice.uniqueID
    case camera(deviceID: String?)
    /// deviceID = 입력 장치(AVCaptureDevice.uniqueID), appBundleID = 특정 앱 소리(ScreenCaptureKit)
    case audio(deviceID: String?, appBundleID: String?)

    static func `default`(for kind: SourceKind) -> SourceConfig {
        switch kind {
        case .window:  .window(bundleID: nil, windowTitle: nil, cropChrome: false, captureAppAudio: false)
        case .screen: .screen(displayID: nil, name: nil)
        case .browser: .browser(url: nil, transparentBackground: true, width: 1920, height: 1080)
        case .camera:  .camera(deviceID: nil)
        case .audio:   .audio(deviceID: nil, appBundleID: nil)
        case .text: .text(value: "", opaque: false)
        case .media: .media(path: "", loop: true, audioOnly: false)
        case .graphic: .graphic(icon: "", color: "FFFFFF", path: "")
        case .captions: .captions(showSource: false, background: true, fontSize: 56, lines: 1)
        case .slides: .slides
        case .youtube: .youtube(url: "", loop: true)
        }
    }
}

/// 영상·음악 소리가 나가는 곳. 현장 스피커는 이 Mac의 소리 출력(헤드폰 단자·HDMI·오디오 인터페이스)이다.
enum AudioRoute: String, Codable, CaseIterable, Identifiable {
    case both, broadcast, room
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: L("방송+현장")
        case .broadcast: L("방송만")
        case .room: L("현장만")
        }
    }
    var symbol: String {
        switch self {
        case .both: "speaker.wave.2.circle"
        case .broadcast: "dot.radiowaves.left.and.right"
        case .room: "hifispeaker"
        }
    }
    var help: String {
        switch self {
        case .both: L("방송과 이 Mac의 스피커(현장) 모두에서 들립니다")
        case .broadcast: L("방송에만 나갑니다. 현장에서는 들리지 않습니다")
        case .room: L("이 Mac의 스피커(현장)에서만 들립니다. 현장 믹서 소리가 다시 방송으로 들어가는 구성이면 이것을 고르세요")
        }
    }
}

struct Source: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: SourceKind
    var config: SourceConfig
    /// 추가 카메라만의 보정·색 톤·배경 흐림 (nil이면 준비 화면의 공통 설정을 따른다)
    var look: CameraLook? = nil
    /// 가져온 자료의 배경을 투명하게 (윈도우·화면 캡처): nil 끔 · "black" · "white" · "green"
    var keyColor: String? = nil
    /// 영상·음악 소리가 나가는 곳 (nil = 방송만, 예전 동작)
    var audioRoute: AudioRoute? = nil
    /// 문구 소스: 글자 오브젝트 모양 (nil = 예전 방식 — 화면 전체 그림에 글자를 가운데 그림)
    var textStyle: TextObjectStyle? = nil
    /// 고르지 않았을 때: 영상 파일은 방송만(예전 동작), 유튜브는 방송+현장
    var effectiveAudioRoute: AudioRoute { audioRoute ?? (kind == .youtube ? .both : .broadcast) }

    init(id: UUID = UUID(), name: String, kind: SourceKind, config: SourceConfig? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.config = config ?? .default(for: kind)
    }
}

/// 카메라별 화면 설정 (Pro)
struct CameraLook: Codable, Hashable {
    var beauty: Int = 1            // 0 끔, 1 자연스럽게, 2 조금 더
    var tone: Int = 0              // 0 원본, 1 따뜻하게, 2 맑게, 3 차분하게, 4 필름
    var toneAmount: Double = 60    // 0...100
    var blur: Double = 0           // 0...100
}

// MARK: - SceneItem

enum ItemShape: String, Codable, CaseIterable, Identifiable {
    case rect, rounded, circle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rect: L("사각")
        case .rounded: L("둥근 모서리")
        case .circle: L("원")
        }
    }
}

/// 0...1 정규화된 크롭 (각 변에서 잘라낼 비율)
struct NormalizedInsets: Codable, Hashable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    static let zero = NormalizedInsets()
}

/// 봉사자용 "빠른 배치" 버튼
enum PlacementPreset: String, CaseIterable, Identifiable {
    case full, leftHalf, rightHalf, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    /// 반쪽 배치: 상자를 반으로 채우고 소스는 가운데를 기준으로 자동으로 잘라 넣는다
    var isHalf: Bool { self == .leftHalf || self == .rightHalf }

    var title: String {
        switch self {
        case .full: L("전체 화면")
        case .leftHalf: L("왼쪽 절반 (가운데 기준 자동 자르기)")
        case .rightHalf: L("오른쪽 절반 (가운데 기준 자동 자르기)")
        case .topLeft: L("왼쪽 위")
        case .topRight: L("오른쪽 위")
        case .bottomLeft: L("왼쪽 아래")
        case .bottomRight: L("오른쪽 아래")
        }
    }

    /// 정규화 프레임. 작은 화면(PIP)은 너비 28%, 16:9 유지(캔버스도 16:9라 정규화 높이도 0.28).
    var frame: CGRect {
        let s: CGFloat = 0.28, mx: CGFloat = 0.04, my: CGFloat = 0.06
        switch self {
        case .full:        return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leftHalf:    return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:   return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topLeft:     return CGRect(x: mx, y: my, width: s, height: s)
        case .topRight:    return CGRect(x: 1 - mx - s, y: my, width: s, height: s)
        case .bottomLeft:  return CGRect(x: mx, y: 1 - my - s, width: s, height: s)
        case .bottomRight: return CGRect(x: 1 - mx - s, y: 1 - my - s, width: s, height: s)
        }
    }
}

// CGRect는 Hashable이 아니므로 CGRect를 담는 타입은 Equatable까지만
struct SceneItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourceID: Source.ID
    /// 정규화 프레임 (원점 = 왼쪽 위)
    var frame: CGRect = PlacementPreset.full.frame
    var isVisible = true
    var isLocked = false
    var shape: ItemShape = .rect
    var hasBorder = false
    var crop: NormalizedInsets = .zero
    /// 오디오 소스용 (0...1)
    var volume: Float = 1
    var isMuted = false
    /// 회전 (도, 시계 방향). 예전 저장 파일에는 없으므로 선택값
    var rotation: Double? = nil

    /// 회전 각도 (-180...180). 0이면 저장하지 않음
    var angle: Double {
        get { rotation ?? 0 }
        set {
            var a = newValue.truncatingRemainder(dividingBy: 360)
            if a > 180 { a -= 360 } else if a <= -180 { a += 360 }
            rotation = abs(a) < 0.05 ? nil : a
        }
    }
}

// MARK: - Transition

struct SceneTransition: Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case cut, fade, slide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cut: L("컷")
            case .fade: L("페이드")
            case .slide: L("슬라이드")
            }
        }
    }

    var style: Style = .fade
    var duration: Double = 0.5   // 초. .cut 이면 무시

    static let `default` = SceneTransition()
    static let durations: [Double] = [0.3, 0.5, 1.0]
}

// MARK: - ShowScene
// (SwiftUI의 `Scene` 프로토콜과 이름이 겹치지 않도록 ShowScene)

struct ShowScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// 뒤 → 앞 순서. (UI 목록은 reversed()로 "위가 앞"으로 보여준다)
    var items: [SceneItem] = []
    /// nil = 쇼 기본 전환 사용
    var transitionIn: SceneTransition? = nil
}

// MARK: - Templates

/// 새 장면 템플릿. "역할(role)"로 소스를 지정해서, 이미 있는 카메라·마이크는 재사용한다.
struct SceneTemplate: Identifiable, Equatable {
    enum Role: Hashable {
        case mainCamera          // 준비 단계에서 연결한 카메라 (공유)
        case mainMic             // 준비 단계에서 연결한 마이크 (공유)
        case browser(name: String, url: URL?)
        case window(name: String)
        case backgroundMusic
    }

    struct Slot: Equatable {
        var role: Role
        var frame: CGRect
        var shape: ItemShape = .rect
        var hasBorder = false
    }

    let id: String
    let name: String
    let slots: [Slot]           // 뒤 → 앞

    var summary: [String] {
        slots.map { slot in
            switch slot.role {
            case .mainCamera: slot.frame == PlacementPreset.full.frame ? L("카메라 · 전체") : L("카메라 · 작은 화면")
            case .mainMic: L("마이크")
            case .browser(let n, let url): url == nil ? L("문구") + " · \(n)" : L("브라우저") + " · \(n)"
            case .window(let n): L("윈도우") + " · \(n)"
            case .backgroundMusic: L("오디오 · 배경음악")
            }
        }
    }

    // 하단 자막 영역
    private static let lowerThird = CGRect(x: 0.04, y: 0.82, width: 0.42, height: 0.12)
    private static let lyricsBand = CGRect(x: 0, y: 0.74, width: 1, height: 0.26)

    static let blank = SceneTemplate(id: "blank", name: L("빈 장면"), slots: [])

    static let waiting = SceneTemplate(id: "waiting", name: L("대기 화면"), slots: [
        .init(role: .browser(name: L("안내 문구"), url: nil), frame: PlacementPreset.full.frame),
        .init(role: .backgroundMusic, frame: .zero),
    ])

    static let worship = SceneTemplate(id: "worship", name: L("찬양"), slots: [
        .init(role: .mainCamera, frame: PlacementPreset.full.frame),
        .init(role: .browser(name: L("가사"), url: nil), frame: lyricsBand),
        .init(role: .mainMic, frame: .zero),
    ])

    static let sermon = SceneTemplate(id: "sermon", name: L("설교"), slots: [
        .init(role: .mainCamera, frame: PlacementPreset.full.frame),
        .init(role: .browser(name: L("이름 자막"), url: nil), frame: lowerThird),
        .init(role: .mainMic, frame: .zero),
    ])

    static let scripture = SceneTemplate(id: "scripture", name: L("말씀·자료"), slots: [
        .init(role: .window(name: L("슬라이드")), frame: PlacementPreset.full.frame),
        .init(role: .browser(name: L("이름 자막"), url: nil), frame: lowerThird),
        .init(role: .mainCamera, frame: PlacementPreset.bottomRight.frame, shape: .rounded, hasBorder: true),
        .init(role: .mainMic, frame: .zero),
    ])

    static let ending = SceneTemplate(id: "ending", name: L("종료"), slots: [
        .init(role: .browser(name: L("종료 문구"), url: nil), frame: PlacementPreset.full.frame),
        .init(role: .backgroundMusic, frame: .zero),
    ])

    static let all: [SceneTemplate] = [blank, waiting, worship, sermon, scripture, ending]
}

struct StudioDeviceChoice: Identifiable, Hashable { let id: String; let name: String }

// MARK: - 캔버스 편집 (룰러 가이드 · 정렬)

enum CanvasAxis: String, Codable, Hashable {
    /// 세로선 (x 위치)
    case vertical
    /// 가로선 (y 위치)
    case horizontal
}

/// 룰러에서 끌어 만든 사용자 가이드 (0...1 정규화 위치)
struct CanvasGuide: Identifiable, Codable, Equatable {
    var id = UUID()
    var axis: CanvasAxis
    var position: CGFloat
}

enum CanvasAlign: CaseIterable {
    case left, centerX, right, top, centerY, bottom
    var title: String {
        switch self {
        case .left: L("왼쪽")
        case .centerX: L("가운데")
        case .right: L("오른쪽")
        case .top: L("위")
        case .centerY: L("중간")
        case .bottom: L("아래")
        }
    }
    var symbol: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerX: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerY: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
}


// MARK: - 프레젠테이션 앱

enum PresentationApps {
    static func isPresentation(_ bundle: String?) -> Bool {
        guard let b = bundle?.lowercased() else { return false }
        return b == "com.microsoft.powerpoint" || b == "com.apple.iwork.keynote" || b.hasPrefix("com.renewedvision.")
    }
    static func name(_ bundle: String?) -> String? {
        guard let b = bundle?.lowercased() else { return nil }
        if b == "com.microsoft.powerpoint" { return "PowerPoint" }
        if b == "com.apple.iwork.keynote" { return "Keynote" }
        if b.hasPrefix("com.renewedvision.") { return "ProPresenter" }
        return nil
    }
}

/// 연결된 모니터 (이름·UUID)
struct DisplayChoice: Identifiable, Hashable {
    let id: String          // CGDisplay UUID
    let displayID: CGDirectDisplayID
    let name: String
    let size: CGSize
    let isMain: Bool

    @MainActor static func current() -> [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return DisplayChoice(id: text, displayID: id, name: screen.localizedName,
                                 size: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)),
                                 isMain: id == CGMainDisplayID())
        }
    }
}


/// 영상 파일 재생 상태 (libobs obs_media_state)
struct MediaPlayState: Equatable {
    var state: Int = 0          // 0 없음 · 1 재생 · 2 여는 중 · 3 버퍼링 · 4 멈춤 · 5 정지 · 6 끝 · 7 오류
    var time: Double = 0        // ms
    var duration: Double = 0    // ms
    var loop = false
    var isPlaying: Bool { state == 1 || state == 2 || state == 3 }
}
