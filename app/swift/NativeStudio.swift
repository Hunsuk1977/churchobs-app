// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit
import Observation

@MainActor
final class NativeCompositor: SceneCompositor {
    weak var bridge: (any WSStudioNativeBridge)?
    weak var owner: StudioSession?
    var pending: [String: Any]?
    var lastPreview: Data?
    init(bridge: any WSStudioNativeBridge) { self.bridge = bridge }

    func payload(_ scene: ShowScene, sources: [Source], transition: SceneTransition) -> [String: Any] {
        YouTubePlayers.shared.prune(keep: Set(sources.filter { $0.kind == .youtube }.map(\.id)))
        let definitions: [[String: Any]] = sources.map { source in
            var value: [String: Any] = ["id": source.id.uuidString, "kind": source.kind.rawValue]
            switch source.config {
            case let .camera(id):
                var device = id ?? ""
                if let owner, !owner.account.features.isPro, source.id != owner.store.mainCameraSourceID,
                   !device.isEmpty, device != (owner.store.mainCameraDeviceID ?? "") { device = "" }   // 무료: 카메라 1대
                value["device"] = device
                // 추가 카메라만의 보정·색 톤 (Pro). 무료는 보내지 않아 공통 설정(꺼짐)을 따른다
                if let look = source.look, owner?.account.features.beauty ?? true {
                    value["look"] = ["beauty": look.beauty, "tone": look.tone,
                                     "amount": look.toneAmount / 100, "blur": look.blur / 100]
                }
            case let .audio(id, _): value["device"] = id ?? ""
            case let .screen(display, _): value["display"] = display ?? ""; if let key = source.keyColor { value["key"] = key }
            case let .window(bundle, title, _, audio): value["bundle"] = bundle ?? ""; value["title"] = title ?? ""; value["captureAudio"] = audio; value["anyWindow"] = PresentationApps.isPresentation(bundle); if let key = source.keyColor { value["key"] = key }; if let id = owner?.store.runtimeWindowIDs[source.id] { value["windowID"] = id }
            case let .browser(url, _, _, _): value["url"] = url?.absoluteString ?? ""
            case let .text(text, opaque):
                if let style = source.textStyle, let file = TextRenderer.render(sourceID: source.id, text: text, style: style) {
                    // 글자 오브젝트: 글자 크기에 맞춘 투명 그림
                    value["kind"] = "media"; value["path"] = file.path; value["loop"] = false; value["audioOnly"] = false
                } else {
                    value["kind"] = "text"; value["text"] = text; value["opaque"] = opaque
                }
            case let .media(path, loop, audioOnly): value["kind"] = "media"; value["path"] = path; value["loop"] = loop; value["audioOnly"] = audioOnly; value["monitor"] = source.effectiveAudioRoute.rawValue
            case .slides: break
            case .youtube:
                value["windowID"] = YouTubePlayers.shared.windowNumber(for: source) ?? 0
                value["monitor"] = source.effectiveAudioRoute.rawValue
            case let .captions(showSource, background, fontSize, lines):
                value["showSource"] = showSource; value["background"] = background; value["fontSize"] = fontSize; value["lines"] = lines
            case let .graphic(_, _, path): value["kind"] = "media"; value["path"] = path; value["loop"] = false; value["audioOnly"] = false
            }
            return value
        }
        let items: [[String: Any]] = scene.items.map { item in
            ["id": item.id.uuidString, "source": item.sourceID.uuidString, "x": Double(item.frame.minX), "y": Double(item.frame.minY),
             "width": Double(item.frame.width), "height": Double(item.frame.height), "visible": item.isVisible,
             "shape": item.shape.rawValue, "border": item.hasBorder, "volume": item.volume, "muted": item.isMuted,
             "crop": ["left": Double(item.crop.left), "top": Double(item.crop.top), "right": Double(item.crop.right), "bottom": Double(item.crop.bottom)],
             "rotation": item.angle]
        }
        var graph: [String: Any] = ["sceneID": scene.id.uuidString, "name": scene.name, "sources": definitions, "items": items,
                                   "transition": transition.style.rawValue, "duration": transition.duration]
        if let owner { graph = owner.withCountdown(graph, sceneID: scene.id) }
        if owner?.account.features.watermark ?? false {
            var sources = graph["sources"] as? [[String: Any]] ?? [], items = graph["items"] as? [[String: Any]] ?? []
            sources.append(["id": "runtime-watermark", "kind": "text", "text": L("Church OBS · 무료 버전"), "opaque": false, "corner": true, "fontSize": 26])
            items.append(["id": "runtime-watermark-item", "source": "runtime-watermark", "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0,
                          "visible": true, "shape": "rect", "border": false, "volume": 0.0, "muted": true])
            graph["sources"] = sources; graph["items"] = items
        }
        return graph
    }
    func present(_ scene: ShowScene, sources: [Source], transition: SceneTransition) -> Bool {
        pending = nil; lastPreview = nil
        guard let bridge else { owner?.message = L("엔진 연결이 없습니다."); return false }
        let accepted = bridge.applySceneGraph(payload(scene, sources: sources, transition: transition), preview: false)
        if !accepted { owner?.renderError = bridge.studioState()["error"] as? String ?? L("장면 전환에 실패했습니다.") }
        if accepted { owner?.renderError = ""; YouTubePlayers.shared.live(Self.youtubeIDs(in: scene, sources: sources)) }
        return accepted
    }
    func updatePreview(_ scene: ShowScene, sources: [Source]) {
        pending = payload(scene, sources: sources, transition: .init(style: .cut, duration: 0))
        // 장면 편집 중에는 편집하는 장면의 유튜브를 재생해 미리 볼 수 있게
        if owner?.store.isInPerformanceMode != true { YouTubePlayers.shared.live(Self.youtubeIDs(in: scene, sources: sources)) }
    }

    static func youtubeIDs(in scene: ShowScene, sources: [Source]) -> Set<Source.ID> {
        let tube = Set(sources.filter { $0.kind == .youtube }.map(\.id))
        return Set(scene.items.filter { $0.isVisible && tube.contains($0.sourceID) }.map(\.sourceID))
    }

    func probeAudio(_ deviceID: String?) {
        _ = bridge?.studioCommand("audioProbe", arguments: ["id": deviceID ?? ""])
    }

    /// 출력 창 전용 장면 (nil = 송출 화면 그대로)
    func showOnProjector(_ scene: ShowScene?, sources: [Source]) {
        guard let bridge else { return }
        var graph: [String: Any] = [:]
        if let scene { graph = payload(scene, sources: sources, transition: .init(style: .cut, duration: 0)) }
        if !bridge.studioCommand("projectorScene", arguments: graph) {
            owner?.renderError = bridge.studioState()["error"] as? String ?? L("출력 창 장면을 만들지 못했습니다.")
        }
        YouTubePlayers.shared.setProjector(scene.map { Self.youtubeIDs(in: $0, sources: sources) } ?? [])
    }

    func mediaControl(_ sourceID: Source.ID, action: String, loop: Bool) {
        _ = bridge?.studioCommand("media", arguments: ["id": sourceID.uuidString, "action": action, "loop": loop])
    }

    /// 진행 중 소리 나가는 곳만 바꾸기 (재생을 끊지 않는다)
    func setAudioRoute(_ sourceID: Source.ID, route: AudioRoute) {
        // 유튜브 "방송만"은 웹 소리를 현장 스피커에서 끄는 탭이 필요하다 → 엔진이 처리
        _ = bridge?.studioCommand("audioMonitor", arguments: ["id": sourceID.uuidString, "mode": route.rawValue])
    }

    /// 진행(스튜디오) 화면: 다음에 내보낼 장면을 미리보기에 바로 올린다. nil이면 빈 화면
    func cue(_ scene: ShowScene?, sources: [Source]) {
        guard let bridge else { return }
        lastPreview = nil; pending = nil
        var graph: [String: Any] = scene.map { payload($0, sources: sources, transition: .init(style: .cut, duration: 0)) }
            ?? ["sceneID": "", "name": "", "sources": [[String: Any]](), "items": [[String: Any]](), "transition": "cut", "duration": 0.0]
        graph["studio"] = true
        if !bridge.applySceneGraph(graph, preview: true) {
            owner?.renderError = bridge.studioState()["error"] as? String ?? L("다음 장면 미리보기를 만들지 못했습니다.")
        }
    }

    // 드래그 중 빠른 경로: 마우스 이벤트가 몰려도 한 번에 하나만 엔진으로 보낸다
    private var pendingLayout: [[String: Any]]?
    private var layoutScheduled = false
    func updateLayout(_ items: [SceneItem]) {
        pendingLayout = items.map { item in
            ["id": item.id.uuidString, "x": Double(item.frame.minX), "y": Double(item.frame.minY),
             "width": Double(item.frame.width), "height": Double(item.frame.height),
             "crop": ["left": Double(item.crop.left), "top": Double(item.crop.top), "right": Double(item.crop.right), "bottom": Double(item.crop.bottom)],
             "rotation": item.angle]
        }
        guard !layoutScheduled else { return }
        layoutScheduled = true
        Task { @MainActor [weak self] in self?.flushLayout() }
    }
    private func flushLayout() {
        layoutScheduled = false
        guard let items = pendingLayout, let bridge else { return }
        pendingLayout = nil
        _ = bridge.updatePreviewLayout?(items)
    }
    func flush() {
        guard let pending, let bridge else { return }
        let bytes: Data
        do { bytes = try JSONSerialization.data(withJSONObject: pending, options: [.sortedKeys]) }
        catch { owner?.renderError = L("레이어 데이터가 올바르지 않습니다."); return }
        guard bytes != lastPreview else { return }
        lastPreview = bytes
        if !bridge.applySceneGraph(pending, preview: true) { owner?.renderError = bridge.studioState()["error"] as? String ?? L("미리보기 연결에 실패했습니다.") } else { owner?.renderError = "" }
    }
}

@MainActor
@Observable
final class StudioSession {
    let store: ShowStore
    /// 단계: 0 준비 · 1 장면 · 2 자료 · 3 진행
    static let scenes = 1
    static let materials = 2
    static let performance = 3
    var phase = 0
    @ObservationIgnored private var projectorWasOpen = false
    var state: [String: Any] = [:]
    var message = ""
    var renderError = ""
    var cameraChoice = ""
    var microphoneChoice = ""
    var broadcastChoice = ""
    var showReview = false
    var reviewed = false
    var countdownMinutes = 5
    var countdownRemaining = 300
    var countdownAuto = false
    var countdownRunning = false
    var countdownVisible = false
    var countdownTarget: UUID?
    @ObservationIgnored weak var bridge: (any WSStudioNativeBridge)?
    /// 스튜디오 모드의 실제 송출 화면 (엔진이 지원하지 않으면 nil)
    @ObservationIgnored let programView: NSView?
    /// 로그인·요금제·시나리오
    let account: AccountService
    @ObservationIgnored var lastEntitlementCheck: TimeInterval = 0
    @ObservationIgnored var activeObserver: NSObjectProtocol?
    @ObservationIgnored var urlObserver: NSObjectProtocol?
    let compositor: NativeCompositor
    @ObservationIgnored var timer: Timer?
    @ObservationIgnored var persistenceBlocked = false
    @ObservationIgnored var lastSaved: Data?
    @ObservationIgnored var lastObserved: Data?
    @ObservationIgnored var dirtySince: TimeInterval = 0
    /// 마지막으로 이 Mac에 저장한 시각 (화면 표시용)
    var lastSavedAt: Date?
    @ObservationIgnored var deadline: TimeInterval = 0
    @ObservationIgnored var deviceSignature = ""
    @ObservationIgnored var lastRuntimeSecond = -1
    let saveURL: URL
    let preparationSceneID = UUID()

    init(bridge: any WSStudioNativeBridge, loadSaved: Bool = true) {
        _ = VideoQuality.running   // 엔진이 시작한 화질을 지금 고정 (나중에 바꿔도 다시 시작 전까지는 그대로)
        self.bridge = bridge
        programView = bridge.programPreviewView?()
        account = AccountService(networkEnabled: loadSaved)
        store = ShowStore.starter()
        compositor = NativeCompositor(bridge: bridge)
        saveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChurchOBS/scene-show-v1.json")
        let initialSnapshot = store.snapshot
        if loadSaved, FileManager.default.fileExists(atPath: saveURL.path) {
            do { try store.load(from: saveURL); try validateSnapshot() }
            catch { store.load(initialSnapshot); persistenceBlocked = true; message = "장면 설정을 불러오지 못했습니다. 원본 파일과 자동 저장은 보존합니다. \(error.localizedDescription)" }
        } else if loadSaved {
            let old = bridge.studioState()
            if let texts = old["legacyTexts"] as? [String] {
                for (index, scene) in store.scenes.enumerated() where index < texts.count {
                    if let item = scene.items.first(where: { store.source($0.sourceID)?.kind == .text }), let si = store.sources.firstIndex(where: { $0.id == item.sourceID }) {
                        let opaque = index == 0 || index == 4
                        store.sources[si].config = .text(value: texts[index], opaque: opaque)
                    }
                }
            }
            for (key, music) in [("legacyVideos", false), ("legacyImages", false), ("legacyMusic", true)] {
                guard let paths = old[key] as? [String] else { continue }
                for (index, path) in paths.enumerated() where index < store.scenes.count && !path.isEmpty {
                    let source = Source(name: URL(fileURLWithPath: path).lastPathComponent, kind: music ? .audio : .media,
                                        config: .media(path: path, loop: true, audioOnly: music))
                    store.sources.append(source)
                    var item = SceneItem(sourceID: source.id, frame: music ? .zero : PlacementPreset.full.frame)
                    if music { item.volume = 0.25 }
                    store.scenes[index].items.insert(item, at: 0)
                    if !music, (index == 0 || index == 4), let textItem = store.scenes[index].items.first(where: { store.source($0.sourceID)?.kind == .text }), let si = store.sources.firstIndex(where: { $0.id == textItem.sourceID }), case let .text(value, _) = store.sources[si].config {
                        store.sources[si].config = .text(value: value, opaque: false)
                    }
                }
            }
        }
        store.compositor = compositor; compositor.owner = self
        store.openProjectorWindow = { [weak self] in self?.command("projector", ["windowed": true]) }
        if !loadSaved { return }
        tick()
        // 앱을 끌 때 마지막 변경도 바로 저장 (0.7초 기다리지 않음)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave(force: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        // 계정: 저장된 로그인으로 요금제·시나리오·기본 세팅 받기
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.account.bootstrap(allowDowngrade: !self.locked)
            await self.applyCloudDefaults()
            self.lastEntitlementCheck = ProcessInfo.processInfo.systemUptime
        }
        // 브라우저에서 돌아오는 churchobs:// 링크 (Google 로그인·결제)
        urlObserver = NotificationCenter.default.addObserver(forName: Notification.Name("WSOpenChurchOBSURL"), object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor [weak self] in await self?.account.handleOpenURL(url) }
        }
        // 결제하고 앱으로 돌아오면 요금제 다시 확인
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.account.signedIn else { return }
                await self.account.refreshEntitlement(allowDowngrade: !self.locked)
                self.lastEntitlementCheck = ProcessInfo.processInfo.systemUptime
            }
        }
    }
    func flag(_ key: String) -> Bool { state[key] as? Bool ?? false }
    var locked: Bool { flag("recording") || flag("stopping") || flag("streaming") || flag("busy") || !(state["activeBroadcast"] as? String ?? "").isEmpty }
    var errorText: String { store.lastError ?? (!renderError.isEmpty ? renderError : message.isEmpty ? state["error"] as? String ?? "" : message) }
    func command(_ command: String, _ args: [String: Any] = [:]) {
        if command == "beauty", !account.features.beauty {
            let turningOff = (args["preset"] as? Int) == 0 || (args["compare"] as? Bool) == false
            if !turningOff { message = L("자연 보정은 Pro 기능입니다. 상단 계정 메뉴에서 업그레이드할 수 있습니다."); return }
        }
        if command == "look", !account.features.beauty {
            let turningOff = (args["tone"] as? Int ?? 0) == 0 && (args["blur"] as? Double ?? 0) == 0
            if !turningOff { message = L("색 톤과 배경 흐림은 Pro 기능입니다. 상단 계정 메뉴에서 업그레이드할 수 있습니다."); return }
        }
        if command == "record", !flag("recording"), phase != Self.performance {
            guard let selected = store.selectedScene, compositor.present(selected, sources: store.sources, transition: .init(style: .cut, duration: 0)) else { return }
        }
        guard bridge?.studioCommand(command, arguments: args) == true else { message = L("현재 상태에서는 이 작업을 진행할 수 없습니다."); return }
        message = ""; tick()
    }
    func requestPhase(_ next: Int) {
        guard next != phase else { return }
        if locked { message = L("방송·녹화·연결 작업을 마친 뒤 화면을 바꿀 수 있습니다."); return }
        if next == Self.performance {
            guard flag("ready"), !store.scenes.isEmpty else { message = L("영상 엔진과 장면을 먼저 준비하세요."); return }
            showReview = true; return
        }
        pauseCountdown()
        guard bridge?.studioCommand("mode", arguments: ["performance": false]) == true else { return }
        phase = next; reviewed = false; store.isInPerformanceMode = false; store.editingLocked = false
        compositor.lastPreview = nil; store.refreshPreview()
    }
    func enterPerformance() {
        guard reviewed, !locked, bridge?.studioCommand("mode", arguments: ["performance": true]) == true else { return }
        phase = Self.performance; store.isInPerformanceMode = true; store.editingLocked = true
        if let first = store.scenes.first { store.goLive(first.id) }
        if store.programSceneID == nil {
            phase = Self.scenes; store.isInPerformanceMode = false; store.editingLocked = false
            _ = bridge?.studioCommand("mode", arguments: ["performance": false])
        }
    }
    func audioLevel(_ id: UUID) -> Float {
        let levels = state["levels"] as? [String: NSNumber] ?? [:]
        return levels[id.uuidString]?.floatValue ?? (id == store.mainMicSourceID ? (state["micLevel"] as? NSNumber)?.floatValue ?? 0 : 0)
    }
    func tick() {
        guard let bridge else { return }
        state = bridge.studioState()
        // 출력 창을 닫으면(빨간 단추 포함) 다음에 열 때는 송출 화면 그대로
        let projectorOpen = flag("projector")
        if projectorWasOpen && !projectorOpen && store.projectorSceneID != nil { store.setProjectorScene(nil) }
        projectorWasOpen = projectorOpen
        if store.projectorOpen != projectorOpen { store.projectorOpen = projectorOpen }
        if let raw = state["media"] as? [String: [String: NSNumber]] {
            var media: [UUID: MediaPlayState] = [:]
            for (key, v) in raw {
                guard let id = UUID(uuidString: key) else { continue }
                media[id] = MediaPlayState(state: v["state"]?.intValue ?? 0, time: v["time"]?.doubleValue ?? 0,
                                           duration: v["duration"]?.doubleValue ?? 0, loop: v["loop"]?.boolValue ?? false)
            }
            if store.mediaStates != media { store.mediaStates = media }
        }
        if cameraChoice.isEmpty { cameraChoice = state["cameraID"] as? String ?? "" }
        if microphoneChoice.isEmpty { microphoneChoice = state["microphoneID"] as? String ?? "" }
        if broadcastChoice.isEmpty { broadcastChoice = state["broadcastID"] as? String ?? "" }
        if !(state["activeBroadcast"] as? String ?? "").isEmpty { phase = Self.performance; store.isInPerformanceMode = true }
        store.editingLocked = phase == Self.performance || locked
        store.broadcasting = flag("live")
        if let raw = state["sourceSizes"] as? [String: [NSNumber]] {
            var sizes: [UUID: CGSize] = [:]
            for (key, value) in raw where value.count == 2 {
                if let id = UUID(uuidString: key) { sizes[id] = CGSize(width: value[0].doubleValue, height: value[1].doubleValue) }
            }
            if sizes != store.sourceSizes { store.sourceSizes = sizes }
        }
        func choices(_ key: String) -> [StudioDeviceChoice] {
            (state[key] as? [[String: String]] ?? []).compactMap { v in
                guard let id = v["id"], let name = v["name"] else { return nil }
                return StudioDeviceChoice(id: id, name: name)
            }
        }
        let cams = choices("cameras"), mics = choices("microphones")
        if cams != store.cameraDevices { store.cameraDevices = cams }
        if mics != store.microphoneDevices { store.microphoneDevices = mics }
        let probe = (state["probeLevel"] as? NSNumber)?.floatValue ?? 0
        if abs(probe - store.probeLevel) > 0.001 { store.probeLevel = probe }
        if let raw = state["sourceWarnings"] as? [String: String] {
            var warnings: [UUID: String] = [:]
            for (key, value) in raw { if let id = UUID(uuidString: key) { warnings[id] = value } }
            if warnings != store.sourceWarnings { store.sourceWarnings = warnings }
        }
        let signature = "\(flag("ready"))-\(flag("camera"))-\(flag("microphone"))-\(state["cameraID"] ?? "")-\(state["microphoneID"] ?? "")"
        if signature != deviceSignature {
            deviceSignature = signature; compositor.lastPreview = nil
            if flag("camera"), let id = store.mainCameraSourceID, let i = store.sources.firstIndex(where: { $0.id == id }) { store.sources[i].config = .camera(deviceID: state["cameraID"] as? String) }
            if flag("microphone"), let id = store.mainMicSourceID, let i = store.sources.firstIndex(where: { $0.id == id }) { store.sources[i].config = .audio(deviceID: state["microphoneID"] as? String, appBundleID: nil) }
        }
        if phase != Self.performance, flag("ready"), !locked {
            if phase == 0, flag("camera"), let id = store.mainCameraSourceID {
                let camera = ShowScene(id: preparationSceneID, name: L("카메라 점검"), items: [SceneItem(sourceID: id)])
                compositor.updatePreview(camera, sources: store.sources)
            } else { store.refreshPreview() }
            compositor.flush()
        }
        updateCountdown()
        autosave()
        accountTick()
    }

    // MARK: 계정·요금제

    private func accountTick() {
        // 방송·녹화 중에는 요금제를 내리지 않는다 (예배 도중 워터마크가 생기지 않게)
        account.reevaluate(allowDowngrade: !locked)
        let pro = account.features.isPro
        if store.isPro != pro { store.isPro = pro; compositor.lastPreview = nil }
        // 무료: 자연 보정 끄기
        if !account.features.beauty, !locked, (state["beautyPreset"] as? Int ?? 0) != 0 {
            _ = bridge?.studioCommand("beauty", arguments: ["preset": 0])
        }
        if !account.features.beauty, !locked, (state["lookTone"] as? Int ?? 0) != 0 || ((state["lookBlur"] as? NSNumber)?.doubleValue ?? 0) > 0 {
            _ = bridge?.studioCommand("look", arguments: ["tone": 0, "blur": 0.0])
        }
        // 10분마다 요금제 다시 확인
        let now = ProcessInfo.processInfo.systemUptime
        if account.signedIn, lastEntitlementCheck > 0, now - lastEntitlementCheck > 600 {
            lastEntitlementCheck = now
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.account.refreshEntitlement(allowDowngrade: !self.locked)
            }
        }
        // 기본 세팅 올리기 (바뀌었을 때만, 3초 모아서)
        if account.signedIn { account.defaultsChanged(currentDefaults) }
    }

    var currentDefaults: StudioDefaults {
        var beauty: [String: Double] = [:]
        for key in ["strength", "skin", "shape", "eyes", "brows"] {
            if let v = (state[key] as? NSNumber)?.doubleValue { beauty[key] = v.rounded() }
        }
        return StudioDefaults(defaultTransition: store.defaultTransition,
                              beautyPreset: state["beautyPreset"] as? Int,
                              beauty: beauty.isEmpty ? nil : beauty,
                              lookTone: state["lookTone"] as? Int,
                              lookToneAmount: ((state["lookToneAmount"] as? NSNumber)?.doubleValue).map { $0.rounded() },
                              lookBlur: ((state["lookBlur"] as? NSNumber)?.doubleValue).map { $0.rounded() },
                              countdownMinutes: countdownMinutes, countdownAuto: countdownAuto,
                              lastScenarioID: account.currentScenarioID)
    }

    func applyCloudDefaults() async {
        guard let d = await account.pullDefaults() else { return }
        if let t = d.defaultTransition { store.defaultTransition = t }
        if let m = d.countdownMinutes { countdownMinutes = min(max(m, 1), 180) }
        if let a = d.countdownAuto { countdownAuto = a }
        if account.features.beauty, !locked {
            if let p = d.beautyPreset { _ = bridge?.studioCommand("beauty", arguments: ["preset": p]) }
            if let values = d.beauty, !values.isEmpty { _ = bridge?.studioCommand("beauty", arguments: values) }
            var look: [String: Any] = [:]
            if let t = d.lookTone { look["tone"] = t }
            if let a = d.lookToneAmount { look["amount"] = a }
            if let b = d.lookBlur { look["blur"] = b }
            if !look.isEmpty { _ = bridge?.studioCommand("look", arguments: look) }
        }
    }

    // MARK: 가상 카메라

    var showVirtualCameraHelp = false

    func toggleVirtualCamera() {
        let on = flag("virtualCam")
        if !on, !flag("virtualCamAvailable") { showVirtualCameraHelp = true; return }
        if bridge?.studioCommand("virtualCamera", arguments: ["enabled": !on]) == true {
            message = on ? "" : L("가상 카메라를 켰습니다. Zoom·Meet에서 카메라를 ‘OBS Virtual Camera’로 고르세요.")
        } else {
            message = bridge?.studioState()["error"] as? String ?? L("가상 카메라를 바꾸지 못했습니다.")
            if !on { showVirtualCameraHelp = true }
        }
        tick()
    }

    /// 보관함에서 시나리오 열기 (편집 화면에서만)
    func openScenario(_ id: UUID) async {
        guard !locked, phase != Self.performance else { message = L("방송·녹화를 마치고 장면 편집 화면에서 시나리오를 여세요."); return }
        guard let result = await account.loadScenario(id) else { return }
        let previous = store.snapshot
        store.load(result.snapshot)
        do {
            try validateSnapshot()
            store.title = result.name
            persistenceBlocked = false; compositor.lastPreview = nil
            message = "「\(result.name)」을(를) 열었습니다."
        } catch {
            store.load(previous)
            message = "시나리오를 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveScenario(name: String, overwrite: Bool) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if await account.saveScenario(name: clean, snapshot: store.snapshot, overwrite: overwrite ? account.currentScenarioID : nil) != nil {
            store.title = clean
        }
    }
    func validateSnapshot() throws {
        let ids = Set(store.sources.map(\.id))
        guard ids.count == store.sources.count,
              store.mainCameraSourceID.map({ ids.contains($0) }) ?? true,
              store.mainMicSourceID.map({ ids.contains($0) }) ?? true, Set(store.scenes.map(\.id)).count == store.scenes.count,
              store.scenes.allSatisfy({ scene in Set(scene.items.map(\.id)).count == scene.items.count && scene.items.allSatisfy { ids.contains($0.sourceID) && $0.frame.origin.x.isFinite && $0.frame.origin.y.isFinite && $0.frame.width.isFinite && $0.frame.height.isFinite } }) else {
            throw NSError(domain: "churchobs", code: 1, userInfo: [NSLocalizedDescriptionKey: L("장면이나 소스 참조가 잘못되었습니다.")])
        }
    }
    /// 장면 자동 저장: 바뀐 뒤 0.7초 조용하면 저장 (force = 앱을 끌 때처럼 바로)
    func autosave(force: Bool = false) {
        guard !persistenceBlocked else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let bytes = try encoder.encode(store.snapshot)
            if lastObserved != bytes { lastObserved = bytes; dirtySince = ProcessInfo.processInfo.systemUptime }
            if lastSaved != bytes, force || ProcessInfo.processInfo.systemUptime - dirtySince > 0.7 {
                try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                keepDailyBackup()
                try bytes.write(to: saveURL, options: .atomic); lastSaved = bytes
                lastSavedAt = Date()
            }
        } catch { message = "장면 설정 저장 실패: \(error.localizedDescription)" }
    }

    /// 하루에 한 번, 덮어쓰기 전의 장면 파일을 backups 폴더에 남긴다 (최근 14개)
    private func keepDailyBackup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: saveURL.path) else { return }
        let folder = saveURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let target = folder.appendingPathComponent("scene-show-\(day).json")
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.copyItem(at: saveURL, to: target)
        if let files = try? fm.contentsOfDirectory(atPath: folder.path).filter({ $0.hasPrefix("scene-show-") }).sorted(), files.count > 14 {
            for name in files.prefix(files.count - 14) { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }
    func saveCopy() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "churchobs-scenes.json"
        if panel.runModal() == .OK, let url = panel.url { do { try store.save(to: url) } catch { message = error.localizedDescription } }
    }
    func loadCopy() {
        guard !locked, phase != Self.performance else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let previous = store.snapshot
            do { try store.load(from: url); try validateSnapshot(); persistenceBlocked = false; compositor.lastPreview = nil }
            catch { store.load(previous); message = "장면 설정을 불러오지 못했습니다: \(error.localizedDescription)" }
        }
    }
    func toggleCountdown() {
        guard phase == Self.performance, let program = store.programSceneID, program == store.scenes.first?.id else { message = L("진행 화면에서 현재 장면에 카운트다운을 시작하세요."); return }
        if countdownRunning { pauseCountdown(); return }
        countdownTarget = program
        if countdownRemaining <= 0 || !countdownVisible { countdownRemaining = min(max(countdownMinutes, 1), 180) * 60 }
        deadline = ProcessInfo.processInfo.systemUptime + Double(countdownRemaining)
        countdownRunning = true; countdownVisible = true; lastRuntimeSecond = -1
        updateCountdown()
    }
    func pauseCountdown() {
        if countdownRunning { countdownRemaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))) }
        countdownRunning = false
    }
    func resetCountdown() {
        pauseCountdown(); countdownVisible = false; countdownTarget = nil; countdownRemaining = min(max(countdownMinutes, 1), 180) * 60
        if phase == Self.performance, let scene = store.scenes.first(where: { $0.id == store.programSceneID }) { _ = compositor.present(scene, sources: store.sources, transition: .init(style: .cut, duration: 0)) }
    }
    var countdownLabel: String { String(format: "%02d:%02d", countdownRemaining / 60, countdownRemaining % 60) }
    func updateCountdown() {
        guard countdownRunning else { return }
        guard store.programSceneID == countdownTarget else { pauseCountdown(); return }
        countdownRemaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
        guard countdownRemaining != lastRuntimeSecond else { return }
        lastRuntimeSecond = countdownRemaining
        if countdownRemaining == 0 {
            countdownRunning = false
            if countdownAuto {
                countdownVisible = false
                if store.nextSceneID != nil { store.goNext(); return }
            }
        }
        if let scene = store.scenes.first(where: { $0.id == store.programSceneID }) { _ = compositor.present(scene, sources: store.sources, transition: .init(style: .cut, duration: 0)) }
    }
    func withCountdown(_ graph: [String: Any], sceneID: UUID) -> [String: Any] {
        guard countdownVisible, countdownTarget == sceneID else { return graph }
        var graph = graph
        var sources = graph["sources"] as? [[String: Any]] ?? [], items = graph["items"] as? [[String: Any]] ?? []
        sources.append(["id": "runtime-countdown", "kind": "text", "text": countdownLabel, "opaque": false])
        items.append(["source": "runtime-countdown", "x": 0.2, "y": 0.35, "width": 0.6, "height": 0.3, "visible": true, "shape": "rect", "border": false, "volume": 0, "muted": true])
        graph["sources"] = sources; graph["items"] = items
        return graph
    }
}

/// 엔진 미리보기 NSView는 하나뿐이다. 화면(준비·장면·진행)이 바뀌면 SwiftUI가 새 자리를 만들고,
/// 가장 최근에 창에 나타난 자리 하나만 그 뷰를 갖는다. 사라지는 이전 자리가 뷰를 도로 가져가지 않게 한다.
@MainActor
final class PreviewContainer: NSView {
    private static let all = NSHashTable<PreviewContainer>.weakObjects()
    /// 엔진 뷰(미리보기·송출 화면)마다 지금 그 뷰를 가진 자리
    private static let owners = NSMapTable<NSView, PreviewContainer>.weakToWeakObjects()
    static func owner(of preview: NSView) -> PreviewContainer? { owners.object(forKey: preview) }
    let preview: NSView

    init(preview: NSView) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.all.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { claim() }
        else if Self.owner(of: preview) === self {
            Self.owners.removeObject(forKey: preview)
            Self.all.allObjects.last(where: { $0 !== self && $0.preview === preview && $0.window != nil })?.claim()
        }
    }

    func claim() {
        Self.owners.setObject(self, forKey: preview)
        if preview.superview !== self {
            preview.removeFromSuperview()
            addSubview(preview)
            NSLog("[preview] attached size=%@", NSStringFromSize(bounds.size))
        }
        preview.autoresizingMask = [.width, .height]
        preview.frame = bounds
    }

    override func layout() {
        super.layout()
        if preview.superview === self { preview.frame = bounds }
    }
}

@MainActor
struct EngineSurface: NSViewRepresentable {
    let preview: NSView
    func makeNSView(context: Context) -> PreviewContainer { PreviewContainer(preview: preview) }
    func updateNSView(_ view: PreviewContainer, context: Context) {
        // 소유자일 때만 붙인다 (다른 화면의 자리에서 빼앗아 오지 않음)
        if PreviewContainer.owner(of: preview) === view, view.window != nil, preview.superview !== view { view.claim() }
        view.needsLayout = true
    }
}

@MainActor
@objc(WSSwiftStudioHost)
final class WSSwiftStudioHost: NSObject {
    @objc(makeViewWithBridge:previewView:)
    static func makeView(bridge: any WSStudioNativeBridge, previewView: NSView) -> NSView {
        NSHostingView(rootView: ChurchStudioView(session: StudioSession(bridge: bridge), preview: previewView))
    }
    @objc(verifyIntegrationWithBridge:previewView:)
    static func verify(bridge: any WSStudioNativeBridge, previewView: NSView) -> Bool {
        let store = ShowStore.starter(), adapter = NativeCompositor(bridge: bridge)
        store.compositor = adapter
        guard let scene = store.scenes.first else { return false }
        adapter.updatePreview(scene, sources: store.sources); adapter.flush()
        store.isInPerformanceMode = true; store.goLive(scene.id)
        guard store.programSceneID == scene.id else { return false }
        let host = NSHostingView(rootView: ChurchStudioView(session: StudioSession(bridge: bridge, loadSaved: false), preview: previewView))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        host.layoutSubtreeIfNeeded()
        let okay = previewView.bounds.width >= 500 && previewView.bounds.height >= 250
        window.orderOut(nil)
        return okay
    }
}
