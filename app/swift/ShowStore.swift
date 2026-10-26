// ShowStore.swift
// churchobs — 장면 세트 상태와 편집 동작
// macOS 14+ (Observation). 실제 렌더링/송출은 기존 엔진(Compositor)에 연결한다.

import Foundation
import SwiftUI
import Observation
import CoreGraphics

/// 기존 송출 엔진이 구현할 프로토콜. 이 파일은 엔진 구현을 모른다.
@MainActor
protocol SceneCompositor: AnyObject {
    /// 프로그램 출력을 `scene`으로 바꾼다. (전환 효과 포함)
    func present(_ scene: ShowScene, sources: [Source], transition: SceneTransition) -> Bool
    /// 장면 편집 중 미리보기 갱신 (송출에는 영향 없음)
    func updatePreview(_ scene: ShowScene, sources: [Source])
    /// 드래그 중 빠른 갱신: 이미 미리보기에 있는 레이어의 위치·크기·크롭만 바꾼다
    func updateLayout(_ items: [SceneItem])
    /// 진행 화면: 다음 장면을 미리보기에 올림 (송출에는 영향 없음)
    func cue(_ scene: ShowScene?, sources: [Source])
    /// 소스 추가 창의 소리 확인 미터 (nil = 끄기)
    func probeAudio(_ deviceID: String?)
    /// 영상·음악 소리가 나가는 곳 (방송·현장)
    func setAudioRoute(_ sourceID: Source.ID, route: AudioRoute)
    /// 출력 창(프로젝터)에 송출과 다른 장면 띄우기 (nil = 송출 화면 그대로)
    func showOnProjector(_ scene: ShowScene?, sources: [Source])
    /// 영상 파일 조작: play · pause · restart · stop · loop
    func mediaControl(_ sourceID: Source.ID, action: String, loop: Bool)
}

extension SceneCompositor {
    func mediaControl(_ sourceID: Source.ID, action: String, loop: Bool) {}
    func showOnProjector(_ scene: ShowScene?, sources: [Source]) {}
    func setAudioRoute(_ sourceID: Source.ID, route: AudioRoute) {}
    func updateLayout(_ items: [SceneItem]) {}
    func cue(_ scene: ShowScene?, sources: [Source]) {}
    func probeAudio(_ deviceID: String?) {}
}

@MainActor
@Observable
final class ShowStore {
    // 저장되는 것
    var title: String = L("주일 예배 기본")
    var sources: [Source] = []
    var scenes: [ShowScene] = []
    var defaultTransition: SceneTransition = .default

    /// 1 준비 단계에서 연결한 기본 장치 (템플릿이 여기에 연결됨)
    var mainCameraSourceID: Source.ID?
    var mainMicSourceID: Source.ID?

    // 화면 상태 (저장 안 함)
    var selectedSceneID: ShowScene.ID? {
        didSet { if selectedSceneID != oldValue { selectedItemID = nil; pushPreview() } }
    }
    var runtimeWindowIDs: [UUID: UInt32] = [:]
    var broadcasting = false
    var editingLocked = false
    var isInPerformanceMode = false
    var supportsShapes = true
    var supportsBrowser = false
    var supportsAppAudio = false
    var lastError: String?

    /// 룰러에서 만든 가이드 (저장됨)
    var guides: [CanvasGuide] = []
    /// 엔진이 알려 준 소스 원본 픽셀 크기 (저장 안 함)
    var sourceSizes: [UUID: CGSize] = [:]
    /// 엔진이 만들지 못해 건너뛴 소스와 이유 (예: 자료 창을 찾지 못함)
    var sourceWarnings: [UUID: String] = [:]
    /// 엔진이 찾은 장치 (준비 화면과 같은 목록·같은 ID)
    var cameraDevices: [StudioDeviceChoice] = []
    var microphoneDevices: [StudioDeviceChoice] = []
    /// 소리 확인 미터 값 (0...1)
    var probeLevel: Float = 0
    /// Pro 요금제 여부 (카메라 여러 대 등) — StudioSession이 계정에서 받아 넣는다
    var isPro = false
    /// 속성 패널에서 "자르기" 버튼을 눌렀을 때 캔버스가 자르기 모드로 들어가도록 전달
    var cropRequest: SceneItem.ID?

    var selectedItemID: SceneItem.ID?
    var programSceneID: ShowScene.ID?
    /// 출력 창(프로젝터)에 띄울 장면. nil이면 송출 화면을 그대로 띄운다
    var projectorSceneID: ShowScene.ID?
    /// 출력 창이 열려 있는가 (엔진 상태에서 받아 온다)
    var projectorOpen = false
    /// 출력 창을 별도 창으로 여는 동작 (StudioSession이 넣어 준다)
    @ObservationIgnored var openProjectorWindow: (() -> Void)?
    /// 영상 파일 재생 상태 (엔진에서 0.15초마다)
    var mediaStates: [Source.ID: MediaPlayState] = [:]
    /// 진행 화면 미리보기에 올라가 있는 장면 (전환 버튼·Space로 송출)
    var previewSceneID: ShowScene.ID?

    @ObservationIgnored weak var compositor: SceneCompositor?

    // MARK: 조회

    func source(_ id: Source.ID) -> Source? { sources.first { $0.id == id } }

    var selectedSceneIndex: Int? { scenes.firstIndex { $0.id == selectedSceneID } }

    var selectedScene: ShowScene? {
        get { selectedSceneIndex.map { scenes[$0] } }
    }

    var selectedItem: SceneItem? {
        guard let s = selectedScene else { return nil }
        return s.items.first { $0.id == selectedItemID }
    }

    /// 진행 모드에서 "다음 장면" (Space)
    var nextSceneID: ShowScene.ID? {
        guard let cur = scenes.firstIndex(where: { $0.id == programSceneID }) else { return scenes.first?.id }
        let n = cur + 1
        return n < scenes.count ? scenes[n].id : nil
    }

    // MARK: 장면 편집

    @discardableResult
    func addScene(from template: SceneTemplate, name: String? = nil) -> ShowScene? {
        guard !editingLocked else { return nil }
        var scene = ShowScene(name: name ?? template.name)
        for slot in template.slots {
            let sourceID = resolveSource(for: slot.role)
            var item = SceneItem(sourceID: sourceID, frame: slot.frame)
            item.shape = supportsShapes ? slot.shape : .rect
            item.hasBorder = supportsShapes && slot.hasBorder
            if case .backgroundMusic = slot.role { item.volume = 0.25 }
            scene.items.append(item)
        }
        scenes.append(scene)
        migrateLegacyText()   // 템플릿의 문구도 글자 오브젝트로 (배경은 따로)
        selectedSceneID = scene.id
        selectedItemID = scenes.last?.items.last(where: { source($0.sourceID)?.kind.isVisual == true })?.id
        pushPreview()
        return scenes.last
    }

    func duplicateSelectedScene() {
        guard !editingLocked else { return }
        guard let i = selectedSceneIndex else { return }
        var copy = scenes[i]
        copy.id = UUID()
        copy.name += L(" 사본")
        copy.items = copy.items.map { var it = $0; it.id = UUID(); return it }  // 소스는 공유, 배치는 독립
        scenes.insert(copy, at: i + 1)
        selectedSceneID = copy.id
    }

    func deleteScene(_ id: ShowScene.ID) {
        guard !editingLocked else { return }
        guard !(isInPerformanceMode && programSceneID == id) else { lastError = L("현재 출력 장면은 삭제할 수 없습니다."); return }
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let removed = scenes[index]
        let keptElsewhere = Set(scenes.filter { $0.id != id }.flatMap { $0.items.map(\.sourceID) })
        let orphanSources = sources.filter { s in removed.items.contains { $0.sourceID == s.id } && !keptElsewhere.contains(s.id) }
        lastRemoval = Removal(kind: .scene(removed, index: index, sources: orphanSources), title: "장면 ‘\(removed.name)’")
        if programSceneID == id { programSceneID = nil }
        scenes.removeAll { $0.id == id }
        if projectorSceneID == id { setProjectorScene(nil) }
        if selectedSceneID == id { selectedSceneID = scenes.indices.contains(index) ? scenes[index].id : scenes.last?.id }
        pruneUnusedSources()
    }

    /// 선택한 장면을 한 칸 위(-1)·아래(+1)로
    /// 끌어 놓기로 장면 순서 바꾸기: `id` 장면이 `targetID` 장면 자리로 간다.
    /// 장면 내용은 바뀌지 않으므로 방송 중(진행 화면)에도 허용한다.
    func reorderScene(_ id: ShowScene.ID, onto targetID: ShowScene.ID) {
        guard id != targetID,
              let from = scenes.firstIndex(where: { $0.id == id }),
              let to = scenes.firstIndex(where: { $0.id == targetID }) else { return }
        scenes.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func moveScene(_ id: ShowScene.ID, by delta: Int) {
        guard !editingLocked, let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard scenes.indices.contains(j) else { return }
        scenes.swapAt(i, j)
    }

    // MARK: 되돌리기 (지운 장면·레이어 하나)

    struct Removal {
        enum Kind { case item(SceneItem, sceneID: ShowScene.ID, index: Int, source: Source?), scene(ShowScene, index: Int, sources: [Source]) }
        let kind: Kind
        let title: String
        let at = Date()
    }
    var lastRemoval: Removal?

    func undoRemoval() {
        guard !editingLocked, let r = lastRemoval else { return }
        lastRemoval = nil
        switch r.kind {
        case let .item(item, sceneID, index, removedSource):
            guard let si = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
            if source(item.sourceID) == nil, let removedSource { sources.append(removedSource) }
            if source(item.sourceID) == nil { return }
            scenes[si].items.insert(item, at: min(index, scenes[si].items.count))
            selectedSceneID = sceneID; selectedItemID = item.id
        case let .scene(scene, index, removedSources):
            for s in removedSources where source(s.id) == nil { sources.append(s) }
            scenes.insert(scene, at: min(index, scenes.count))
            selectedSceneID = scene.id
        }
        pushPreview()
    }

    // MARK: 강단 마이크 (장면마다 켜고 끄기)

    /// 이 장면에서 강단 마이크 소리가 나가는가
    func mainMicOn(in scene: ShowScene) -> Bool {
        guard let mic = mainMicSourceID else { return false }
        return scene.items.contains { $0.sourceID == mic && !$0.isMuted }
    }

    /// 마이크가 없는 장면에 강단 마이크를 넣거나, 꺼져 있으면 켠다
    func turnOnMainMic(in sceneID: ShowScene.ID) {
        guard !editingLocked, let si = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let mic = resolveSource(for: .mainMic)
        if let i = scenes[si].items.firstIndex(where: { $0.sourceID == mic }) { scenes[si].items[i].isMuted = false }
        else { scenes[si].items.insert(SceneItem(sourceID: mic, frame: .zero), at: 0) }
        pushPreview()
    }

    func moveScenes(from offsets: IndexSet, to destination: Int) {
        guard !editingLocked else { return }
        scenes.move(fromOffsets: offsets, toOffset: destination)
    }

    // MARK: 글자 오브젝트

    /// 문구 내용·모양 바꾸기. 장면에 놓인 크기 배율과 기준점(정렬 쪽·세로 가운데)은 유지한다
    func updateText(_ id: Source.ID, text: String? = nil, style: TextObjectStyle? = nil) {
        guard !editingLocked, let i = sources.firstIndex(where: { $0.id == id }),
              case let .text(old, opaque) = sources[i].config, let oldStyle = sources[i].textStyle else { return }
        let newText = text ?? old, newStyle = style ?? oldStyle
        let a = TextRenderer.normalizedSize(text: old, style: oldStyle)
        let b = TextRenderer.normalizedSize(text: newText, style: newStyle)
        sources[i].config = .text(value: newText, opaque: opaque)
        sources[i].textStyle = newStyle
        for si in scenes.indices {
            for j in scenes[si].items.indices where scenes[si].items[j].sourceID == id {
                let f = scenes[si].items[j].frame
                let k = a.width > 0 ? f.width / a.width : 1
                let w = b.width * k, h = b.height * k
                let x: CGFloat = newStyle.align == "left" ? f.minX : newStyle.align == "right" ? f.maxX - w : f.midX - w / 2
                scenes[si].items[j].frame = CGRect(x: x, y: f.midY - h / 2, width: w, height: h)
            }
        }
        pushPreview()
    }

    /// 예전 문구(화면 전체 그림)를 글자 오브젝트로 바꾼다. "불투명 배경"이었으면 단색 배경 레이어를 그 아래에 따로 둔다
    func migrateLegacyText() {
        let legacy = sources.filter { $0.kind == .text && $0.textStyle == nil }
        guard !legacy.isEmpty else { return }
        for src in legacy {
            guard let i = sources.firstIndex(where: { $0.id == src.id }), case let .text(value, opaque) = src.config else { continue }
            var style = TextObjectStyle(); style.size = 96   // 예전 기본 글자 크기 (720p 64 → 1080p 기준 96)
            sources[i].textStyle = style
            sources[i].config = .text(value: value, opaque: false)
            let size = TextRenderer.normalizedSize(text: value, style: style)
            var backgroundID: Source.ID?
            if opaque, let file = TextRenderer.solidBackground("0A0A0A") {
                let bg = Source(name: src.name + " " + L("배경"), kind: .media, config: .media(path: file.path, loop: false, audioOnly: false))
                sources.append(bg); backgroundID = bg.id
            }
            for si in scenes.indices {
                var items: [SceneItem] = []
                for item in scenes[si].items {
                    guard item.sourceID == src.id else { items.append(item); continue }
                    if let backgroundID { items.append(SceneItem(sourceID: backgroundID, frame: item.frame)) }
                    var text = item
                    let k = item.frame.width          // 예전 그림 = 화면 전체 폭
                    let w = size.width * k, h = size.height * k
                    text.frame = CGRect(x: item.frame.midX - w / 2, y: item.frame.midY - h / 2, width: w, height: h)
                    items.append(text)
                }
                scenes[si].items = items
            }
        }
    }

    func renameScene(_ id: ShowScene.ID, to name: String) {
        // 이름은 화면 구성과 상관없으므로 진행 중에도 바꿀 수 있다
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].name = name
    }

    func setTransitionIn(_ t: SceneTransition?, for id: ShowScene.ID) {
        guard !editingLocked else { return }
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].transitionIn = t
    }

    // MARK: 소스 편집

    /// 새 소스를 만들어 선택된 장면 맨 앞에 추가
    func addNewSource(kind: SourceKind, name: String, config: SourceConfig) {
        guard !editingLocked else { return }
        let actualKind: SourceKind
        if case .media(_, _, true) = config { actualKind = .audio } else { actualKind = kind }
        var src = Source(name: name, kind: actualKind, config: config)
        if actualKind == .text { src.textStyle = TextObjectStyle() }   // 새 문구는 움직일 수 있는 글자 오브젝트로
        sources.append(src)
        addExistingSource(src.id)
    }

    /// 다른 장면에서 쓰던 소스를 이 장면에도 추가 (장치 공유)
    func addExistingSource(_ sourceID: Source.ID) {
        guard !editingLocked else { return }
        guard let si = selectedSceneIndex, let src = source(sourceID) else { return }
        // 자막 띠(1920×360)는 화면 아래 1/3에
        var frame = src.kind == .captions ? CGRect(x: 0, y: 2.0 / 3.0, width: 1, height: 1.0 / 3.0)
                  : src.kind.isVisual ? PlacementPreset.full.frame : .zero
        // 글자 오브젝트: 글자 크기 그대로, 화면 가운데에
        if src.kind == .text, let style = src.textStyle, case let .text(value, _) = src.config {
            let size = TextRenderer.normalizedSize(text: value, style: style)
            frame = CGRect(x: 0.5 - size.width / 2, y: 0.5 - size.height / 2, width: size.width, height: size.height)
        }
        let item = SceneItem(sourceID: sourceID, frame: frame)
        scenes[si].items.append(item)
        selectedItemID = item.id
        pushPreview()
    }

    func removeItem(_ itemID: SceneItem.ID) {
        guard !editingLocked else { return }
        guard let si = selectedSceneIndex, let index = scenes[si].items.firstIndex(where: { $0.id == itemID }) else { return }
        let removed = scenes[si].items[index]
        lastRemoval = Removal(kind: .item(removed, sceneID: scenes[si].id, index: index, source: source(removed.sourceID)),
                              title: "레이어 ‘\(source(removed.sourceID)?.name ?? "소스")’")
        scenes[si].items.remove(at: index)
        if selectedItemID == itemID {
            // 지운 자리의 다음 레이어를 선택해 연달아 정리하기 쉽게
            let items = scenes[si].items
            selectedItemID = items.isEmpty ? nil : items[min(max(index - 1, 0), items.count - 1)].id
        }
        pruneUnusedSources()
        pushPreview()
    }

    /// UI 목록은 "위가 앞"(reversed) 이므로 여기서 다시 뒤집어 반영
    /// 끌어 놓기로 레이어 순서 바꾸기 (목록은 위가 앞): `id` 레이어가 `targetID` 레이어 자리로 간다
    func reorderItem(_ id: SceneItem.ID, onto targetID: SceneItem.ID) {
        guard !editingLocked, id != targetID, let si = selectedSceneIndex else { return }
        var display = Array(scenes[si].items.reversed())
        guard let from = display.firstIndex(where: { $0.id == id }),
              let to = display.firstIndex(where: { $0.id == targetID }) else { return }
        display.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        scenes[si].items = Array(display.reversed())
        selectedItemID = id
        pushPreview()
    }

    func moveItemsInDisplayOrder(from offsets: IndexSet, to destination: Int) {
        guard !editingLocked else { return }
        guard let si = selectedSceneIndex else { return }
        var display = Array(scenes[si].items.reversed())
        display.move(fromOffsets: offsets, toOffset: destination)
        scenes[si].items = Array(display.reversed())
        pushPreview()
    }

    /// 아이템 하나를 고치는 공통 진입점
    func updateItem(_ itemID: SceneItem.ID, _ change: (inout SceneItem) -> Void) {
        guard !editingLocked else { return }
        guard let si = selectedSceneIndex,
              let ii = scenes[si].items.firstIndex(where: { $0.id == itemID }) else { return }
        change(&scenes[si].items[ii])
        if scenes[si].items[ii].frame != .zero {   // 오디오 아이템(.zero)은 건드리지 않음
            scenes[si].items[ii].frame = Self.clamp(scenes[si].items[ii].frame)
        }
        pushPreview()
    }

    func apply(_ preset: PlacementPreset, to itemID: SceneItem.ID) {
        let size = sourceSizes[selectedScene?.items.first(where: { $0.id == itemID })?.sourceID ?? UUID()]
        updateItem(itemID) { item in
            let wasHalf = item.frame == PlacementPreset.leftHalf.frame || item.frame == PlacementPreset.rightHalf.frame
            item.frame = preset.frame
            if preset.isHalf {
                item.angle = 0
                item.crop = Self.centerCrop(source: size, box: preset.frame)
            } else if wasHalf {
                item.crop = .zero          // 반쪽에서 다른 배치로 가면 자동 자르기를 되돌린다
            }
        }
    }

    /// 상자 비율(출력 픽셀 기준)에 맞도록 소스를 가운데 기준으로 자르는 값. 크기를 모르면 16:9로 본다
    static func centerCrop(source: CGSize?, box: CGRect) -> NormalizedInsets {
        let src = (source.map { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? nil) ?? CGSize(width: 16, height: 9)
        let srcAspect = src.width / src.height
        let boxAspect = (box.width * OutputCanvas.width) / max(box.height * OutputCanvas.height, 1)
        var crop = NormalizedInsets()
        if srcAspect > boxAspect {
            let side = (1 - boxAspect / srcAspect) / 2      // 좌우를 똑같이
            crop.left = side; crop.right = side
        } else if srcAspect < boxAspect {
            let side = (1 - srcAspect / boxAspect) / 2      // 위아래를 똑같이
            crop.top = side; crop.bottom = side
        }
        return crop
    }

    func updateSource(_ id: Source.ID, _ change: (inout Source) -> Void) {
        guard !editingLocked else { return }
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[i])
        pushPreview()
    }

    /// 출력 창에 띄울 장면 고르기 (방송 중에도 가능). nil = 송출 화면 그대로
    func setProjectorScene(_ id: ShowScene.ID?) {
        projectorSceneID = id.flatMap { id in scenes.contains { $0.id == id } ? id : nil }
        refreshProjector()
        // 출력 창이 닫혀 있으면 별도 창으로 연다 (장면만 고르고 아무것도 안 보이는 일이 없게)
        if projectorSceneID != nil, !projectorOpen { openProjectorWindow?() }
    }

    /// 출력 창 장면을 지금 소스 설정으로 다시 그린다
    func refreshProjector() {
        compositor?.showOnProjector(scenes.first { $0.id == projectorSceneID }, sources: sources)
    }

    /// 영상·음악 소리가 나가는 곳. 장면 구성이 바뀌지 않으므로 진행(방송) 중에도 바꿀 수 있다.
    func setAudioRoute(_ id: Source.ID, _ route: AudioRoute) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].audioRoute = route
        compositor?.setAudioRoute(id, route: route)
    }

    /// 영상 재생 조작 (진행 중에도 가능)
    func mediaControl(_ id: Source.ID, _ action: String) {
        guard let src = source(id) else { return }
        switch src.config {
        case .youtube:
            switch action {
            case "restart": YouTubePlayers.shared.restart(id)
            case "play": YouTubePlayers.shared.play(id)
            case "pause", "stop": YouTubePlayers.shared.pause(id)
            default: break
            }
        case .media: compositor?.mediaControl(id, action: action, loop: isLooping(src))
        default: break
        }
    }

    func isLooping(_ src: Source) -> Bool {
        switch src.config {
        case let .media(_, loop, _): loop
        case let .youtube(_, loop): loop
        default: false
        }
    }

    /// 반복 재생 켜기·끄기 (진행 중에도 가능, 재생을 다시 시작하지 않는다)
    func setMediaLoop(_ id: Source.ID, _ loop: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        switch sources[i].config {
        case let .media(path, _, audioOnly):
            sources[i].config = .media(path: path, loop: loop, audioOnly: audioOnly)
            compositor?.mediaControl(id, action: "loop", loop: loop)
        case let .youtube(url, _):
            sources[i].config = .youtube(url: url, loop: loop)
            YouTubePlayers.shared.setLoop(id, loop)
        default: break
        }
    }

    /// 재생 조작이 필요한 영상 소스인가 (영상 파일·음악·유튜브. 사진 제외)
    func isPlayable(_ source: Source) -> Bool {
        switch source.config {
        case .youtube: return true
        case let .media(path, _, audioOnly):
            guard !path.isEmpty else { return false }
            let type = MediaType.of(URL(fileURLWithPath: path))
            return audioOnly || type == .video || type == .audio
        default: return false
        }
    }

    /// 소리가 있는 영상·음악 소스인가 (사진 제외)
    func hasPlayableAudio(_ source: Source) -> Bool {
        if case .youtube = source.config { return true }
        guard case let .media(path, _, audioOnly) = source.config, !path.isEmpty else { return false }
        let type = MediaType.of(URL(fileURLWithPath: path)); return audioOnly || type == .video || type == .audio
    }

    // MARK: 캔버스 편집

    /// 드래그 중: 저장소는 그대로 두고 엔진 미리보기만 즉시 갱신
    func previewLayout(_ itemID: SceneItem.ID, frame: CGRect, crop: NormalizedInsets, angle: Double? = nil) {
        guard !editingLocked, var item = selectedScene?.items.first(where: { $0.id == itemID }) else { return }
        item.frame = frame; item.crop = crop
        if let angle { item.angle = angle }
        compositor?.updateLayout([item])
    }

    // MARK: 미디어·그래픽 넣기

    /// 픽셀 크기의 비율을 지키며 화면 너비의 widthFraction만큼, point(정규화)를 중심으로
    private func placedFrame(pixelSize: CGSize?, widthFraction: CGFloat, at point: CGPoint?) -> CGRect {
        var w = widthFraction
        var h = w * (OutputCanvas.width / OutputCanvas.height)          // 정사각형 기준
        if let px = pixelSize, px.width > 0, px.height > 0 {
            h = w * (OutputCanvas.width / OutputCanvas.height) * (px.height / px.width)
        }
        if h > 0.9 { let k = 0.9 / h; w *= k; h *= k }
        let c = point ?? CGPoint(x: 0.5, y: 0.5)
        return Self.clamp(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    func addMedia(_ url: URL, type: MediaType, pixelSize: CGSize?, at point: CGPoint?) {
        guard !editingLocked, let si = selectedSceneIndex else { lastError = L("먼저 장면을 고르세요."); return }
        if type == .audio {
            addNewSource(kind: .audio, name: url.deletingPathExtension().lastPathComponent,
                         config: .media(path: url.path, loop: true, audioOnly: true))
            return
        }
        // 영상은 기본 한 번 재생 (반복은 아래쪽 재생 막대에서 켠다)
        let src = Source(name: url.deletingPathExtension().lastPathComponent, kind: .media,
                         config: .media(path: url.path, loop: type != .video, audioOnly: false))
        sources.append(src)
        let item = SceneItem(sourceID: src.id, frame: placedFrame(pixelSize: pixelSize, widthFraction: 0.45, at: point))
        scenes[si].items.append(item)
        selectedItemID = item.id
        lastError = nil
        pushPreview()
    }

    func addGraphic(icon: String, color: String, path: String, pixelSize: CGSize, at point: CGPoint?) {
        guard !editingLocked, let si = selectedSceneIndex else { lastError = L("먼저 장면을 고르세요."); return }
        let name = icon.split(separator: ":").last.map(String.init) ?? L("그래픽")
        let src = Source(name: name, kind: .graphic, config: .graphic(icon: icon, color: color, path: path))
        sources.append(src)
        let item = SceneItem(sourceID: src.id, frame: placedFrame(pixelSize: pixelSize, widthFraction: 0.14, at: point))
        scenes[si].items.append(item)
        selectedItemID = item.id
        lastError = nil
        pushPreview()
    }

    // MARK: 레이어 편집 (복제·복사·순서·회전)

    /// 복사한 레이어 (소스는 공유, 배치만 복사)
    @ObservationIgnored var clipboard: SceneItem?

    @discardableResult
    func duplicateItem(_ itemID: SceneItem.ID) -> SceneItem.ID? {
        guard !editingLocked, let si = selectedSceneIndex,
              let i = scenes[si].items.firstIndex(where: { $0.id == itemID }) else { return nil }
        var copy = scenes[si].items[i]
        copy.id = UUID()
        if copy.frame != .zero { copy.frame = Self.clamp(copy.frame.offsetBy(dx: 0.03, dy: 0.03)) }
        scenes[si].items.insert(copy, at: i + 1)
        selectedItemID = copy.id
        pushPreview()
        return copy.id
    }

    func copyItem(_ itemID: SceneItem.ID) {
        clipboard = selectedScene?.items.first { $0.id == itemID }
    }

    func pasteItem() {
        guard !editingLocked, let si = selectedSceneIndex, var item = clipboard, source(item.sourceID) != nil else { return }
        item.id = UUID()
        if scenes[si].items.contains(where: { $0.frame == item.frame }), item.frame != .zero {
            item.frame = Self.clamp(item.frame.offsetBy(dx: 0.03, dy: 0.03))
        }
        scenes[si].items.append(item)
        clipboard = item
        selectedItemID = item.id
        pushPreview()
    }

    enum LayerOrder { case front, forward, backward, back }

    /// items는 뒤 → 앞 순서
    func reorder(_ itemID: SceneItem.ID, _ order: LayerOrder) {
        guard !editingLocked, let si = selectedSceneIndex,
              let i = scenes[si].items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = scenes[si].items.remove(at: i)
        let n = scenes[si].items.count
        let target: Int = switch order {
        case .front: n
        case .forward: min(i + 1, n)
        case .backward: max(i - 1, 0)
        case .back: 0
        }
        scenes[si].items.insert(item, at: target)
        pushPreview()
    }

    func rotate(_ itemID: SceneItem.ID, to degrees: Double) {
        updateItem(itemID) { $0.angle = degrees }
    }

    /// 자른 뒤 실제로 보이는 화면의 가로/세로 비율 (캔버스 정규화 단위 w/h). 크기를 아직 모르면 nil
    func contentAspect(_ item: SceneItem) -> CGFloat? {
        guard let px = sourceSizes[item.sourceID], px.width > 0, px.height > 0 else { return nil }
        let w = px.width * max(1 - item.crop.left - item.crop.right, 0.05)
        let h = px.height * max(1 - item.crop.top - item.crop.bottom, 0.05)
        return (w / h) * (OutputCanvas.height / OutputCanvas.width)
    }

    /// 상자 안에서 실제로 그려지는 영역 (엔진은 비율을 유지해 상자 안에 맞춘다)
    func contentRect(_ item: SceneItem) -> CGRect {
        CropMath.fit(aspect: contentAspect(item), in: item.frame)
    }

    func align(_ itemID: SceneItem.ID, _ a: CanvasAlign) {
        updateItem(itemID) { item in
            switch a {
            case .left: item.frame.origin.x = 0
            case .centerX: item.frame.origin.x = (1 - item.frame.width) / 2
            case .right: item.frame.origin.x = 1 - item.frame.width
            case .top: item.frame.origin.y = 0
            case .centerY: item.frame.origin.y = (1 - item.frame.height) / 2
            case .bottom: item.frame.origin.y = 1 - item.frame.height
            }
        }
    }

    /// 화살표 키 이동 (출력 픽셀 단위)
    func nudge(_ itemID: SceneItem.ID, dxPixels: CGFloat, dyPixels: CGFloat) {
        updateItem(itemID) { item in
            item.frame.origin.x += dxPixels / OutputCanvas.width
            item.frame.origin.y += dyPixels / OutputCanvas.height
        }
    }

    /// 상자를 실제 화면 비율에 딱 맞게 (위아래·좌우 빈 띠 제거)
    /// 모양 바꾸기. 원은 지금 보이는 부분의 가운데를 정사각형으로 잘라 상자도 정사각형으로 맞춘다 (Canva의 원형 프레임처럼)
    func setShape(_ itemID: SceneItem.ID, _ shape: ItemShape) {
        guard let item = selectedScene?.items.first(where: { $0.id == itemID }) else { return }
        let content = contentRect(item)
        updateItem(itemID) { it in
            it.shape = shape
            guard shape == .circle else { return }
            let px = sourceSizes[it.sourceID] ?? CGSize(width: 16, height: 9)
            let w = px.width * (1 - it.crop.left - it.crop.right), h = px.height * (1 - it.crop.top - it.crop.bottom)
            if w > h * 1.001 {
                let e = (w - h) / 2 / px.width
                it.crop.left = min(it.crop.left + e, 0.45); it.crop.right = min(it.crop.right + e, 0.45)
            } else if h > w * 1.001 {
                let e = (h - w) / 2 / px.height
                it.crop.top = min(it.crop.top + e, 0.45); it.crop.bottom = min(it.crop.bottom + e, 0.45)
            }
            let side = min(content.width * OutputCanvas.width, content.height * OutputCanvas.height)
            let nw = side / OutputCanvas.width, nh = side / OutputCanvas.height
            it.frame = CGRect(x: content.midX - nw / 2, y: content.midY - nh / 2, width: nw, height: nh)
        }
    }

    func fitFrameToContent(_ itemID: SceneItem.ID) {
        guard let item = selectedScene?.items.first(where: { $0.id == itemID }) else { return }
        let content = contentRect(item)
        updateItem(itemID) { $0.frame = content }
    }

    func resetCrop(_ itemID: SceneItem.ID) {
        guard let item = selectedScene?.items.first(where: { $0.id == itemID }) else { return }
        let full = CropMath.fullRect(content: contentRect(item), crop: item.crop)
        updateItem(itemID) { $0.crop = .zero; $0.frame = full }
    }

    func addGuide(_ axis: CanvasAxis, at position: CGFloat) {
        guides.append(CanvasGuide(axis: axis, position: min(max(position, 0), 1)))
    }

    func moveGuide(_ id: CanvasGuide.ID, to position: CGFloat) {
        guard let i = guides.firstIndex(where: { $0.id == id }) else { return }
        guides[i].position = min(max(position, 0), 1)
    }

    func removeGuide(_ id: CanvasGuide.ID) { guides.removeAll { $0.id == id } }

    func probeAudio(_ deviceID: String?) {
        if deviceID == nil { probeLevel = 0 }
        compositor?.probeAudio(deviceID)
    }

    /// 준비 화면에서 연결한 장치 ID
    var mainCameraDeviceID: String? {
        guard let id = mainCameraSourceID, case let .camera(device)? = source(id)?.config else { return nil }
        return device
    }
    var mainMicDeviceID: String? {
        guard let id = mainMicSourceID, case let .audio(device, _)? = source(id)?.config else { return nil }
        return device
    }

    func deviceName(_ id: String?, in list: [StudioDeviceChoice]) -> String? {
        guard let id else { return nil }
        return list.first { $0.id == id }?.name
    }

    // MARK: 진행

    func goLive(_ sceneID: ShowScene.ID) {
        guard isInPerformanceMode, let compositor else { lastError = L("진행 화면과 엔진 연결을 먼저 확인하세요."); return }
        guard let scene = scenes.first(where: { $0.id == sceneID }) else { return }
        let t = scene.transitionIn ?? defaultTransition
        if compositor.present(scene, sources: sources, transition: t) {
            programSceneID = sceneID; lastError = nil
            cue(nextSceneID)   // 다음 장면을 자동으로 미리보기에
        }
    }

    func goNext() {
        if let id = nextSceneID { goLive(id) }
    }

    /// 장면을 미리보기에 올리기 (진행 화면에서 장면 버튼 한 번 클릭)
    func cue(_ id: ShowScene.ID?) {
        previewSceneID = id
        guard isInPerformanceMode else { return }
        compositor?.cue(scenes.first { $0.id == id }, sources: sources)
    }

    /// 미리보기 → 송출 (전환 버튼, Space)
    func take() {
        if let id = previewSceneID ?? nextSceneID { goLive(id) }
    }

    // MARK: 내부

    private func resolveSource(for role: SceneTemplate.Role) -> Source.ID {
        switch role {
        case .mainCamera:
            if let id = mainCameraSourceID { return id }
            let s = Source(name: L("카메라 · 강단"), kind: .camera)
            sources.append(s); mainCameraSourceID = s.id
            return s.id
        case .mainMic:
            if let id = mainMicSourceID { return id }
            let s = Source(name: L("강단 마이크"), kind: .audio)
            sources.append(s); mainMicSourceID = s.id
            return s.id
        case .browser(let name, let url):
            let s: Source
            if let url {
                s = Source(name: name, kind: .browser, config: .browser(url: url, transparentBackground: true, width: 1280, height: 720))
            } else {
                let text = name == L("안내 문구") ? L("잠시 후 예배를 시작합니다") : name == L("종료 문구") ? L("함께 예배해 주셔서 감사합니다") : ""
                s = Source(name: name, kind: .text, config: .text(value: text, opaque: name == L("안내 문구") || name == L("종료 문구")))
            }
            sources.append(s)
            return s.id
        case .window(let name):
            let s = Source(name: name, kind: .window)
            sources.append(s)
            return s.id
        case .backgroundMusic:
            let s = Source(name: L("배경음악"), kind: .audio, config: .media(path: "", loop: true, audioOnly: true))
            sources.append(s)
            return s.id
        }
    }

    /// 어느 장면에서도 쓰지 않는 소스 정리 (기본 카메라·마이크는 유지)
    private func pruneUnusedSources() {
        let used = Set(scenes.flatMap { $0.items.map(\.sourceID) })
        sources.removeAll { !used.contains($0.id) && $0.id != mainCameraSourceID && $0.id != mainMicSourceID }
    }

    func refreshPreview() { pushPreview() }

    private func pushPreview() {
        guard let s = selectedScene else { return }
        compositor?.updatePreview(s, sources: sources)
        if projectorSceneID != nil { refreshProjector() }   // 편집한 소스가 출력 창 장면에도 있을 수 있다
    }

    static func clamp(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.03
        var r = r
        r.size.width = min(max(r.width, minSize), 1)
        r.size.height = min(max(r.height, minSize), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }
}

// MARK: - 저장 / 불러오기 ("지난 주 설정 불러오기")

extension ShowStore {
    struct Snapshot: Codable {
        var title: String
        var sources: [Source]
        var scenes: [ShowScene]
        var defaultTransition: SceneTransition
        var mainCameraSourceID: Source.ID?
        var mainMicSourceID: Source.ID?
        /// 0.8.x 이전 저장 파일에는 없음
        var guides: [CanvasGuide]? = nil
        /// 자료 단계에서 고른 소스 (wordalive · window · builtin). 이전 파일에는 없음
        var materialsSource: String? = nil
    }

    var snapshot: Snapshot {
        Snapshot(title: title, sources: sources, scenes: scenes, defaultTransition: defaultTransition,
                 mainCameraSourceID: mainCameraSourceID, mainMicSourceID: mainMicSourceID, guides: guides,
                 materialsSource: MaterialsStore.shared.source?.rawValue)
    }

    func load(_ s: Snapshot) {
        title = s.title; sources = s.sources; scenes = s.scenes
        if let raw = s.materialsSource, let source = MaterialsSource(rawValue: raw) { MaterialsStore.shared.source = source }
        defaultTransition = s.defaultTransition
        mainCameraSourceID = s.mainCameraSourceID; mainMicSourceID = s.mainMicSourceID
        guides = s.guides ?? []
        migrateLegacyText()
        selectedSceneID = scenes.first?.id
        selectedItemID = nil
        programSceneID = nil
        pushPreview()
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(snapshot).write(to: url, options: .atomic)
    }

    func load(from url: URL) throws {
        load(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)))
    }

    /// 처음 실행 시 기본 장면 세트
    static func starter() -> ShowStore {
        let s = ShowStore()
        for t in [SceneTemplate.waiting, .worship, .sermon, .scripture, .ending] { s.addScene(from: t) }
        s.selectedSceneID = s.scenes.first?.id
        return s
    }
}
