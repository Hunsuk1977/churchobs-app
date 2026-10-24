// SceneEditorView.swift
// churchobs — "2 장면" 단계: 장면 목록 | 미리보기 캔버스 + 오디오 | 소스 목록 + 속성
// macOS 14+

import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - 공통 색 / 헬퍼

extension SourceKind {
    var tint: Color {
        switch self {
        case .window:  Color(red: 0.12, green: 0.23, blue: 0.40)
        case .screen: Color(red: 0.12, green: 0.23, blue: 0.40)
        case .browser: Color(red: 0.06, green: 0.37, blue: 0.34)
        case .camera:  Color(red: 0.20, green: 0.25, blue: 0.31)
        case .audio:   Color(white: 0.18)
        case .text: Color(red: 0.06, green: 0.37, blue: 0.34)
        case .media: Color(red: 0.18, green: 0.22, blue: 0.30)
        case .youtube: Color(red: 0.40, green: 0.08, blue: 0.08)
        case .graphic: Color(red: 0.30, green: 0.20, blue: 0.40)
        case .captions: Color(red: 0.36, green: 0.22, blue: 0.10)
        case .slides: Color(red: 0.36, green: 0.22, blue: 0.10)
        }
    }
    var accent: Color {
        switch self {
        case .window, .screen:  Color(red: 0.56, green: 0.69, blue: 0.88)
        case .browser: Color(red: 0.37, green: 0.82, blue: 0.77)
        case .camera, .audio, .media: Color(white: 0.8)
        case .youtube: Color(red: 1.0, green: 0.45, blue: 0.42)
        case .graphic: Color(red: 0.80, green: 0.66, blue: 0.95)
        case .captions, .slides: Color(red: 0.98, green: 0.74, blue: 0.45)
        case .text: Color(red: 0.37, green: 0.82, blue: 0.77)
        }
    }
}

extension ItemShape {
    func shape(in size: CGSize) -> AnyShape {
        switch self {
        case .rect:    AnyShape(Rectangle())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.08, style: .continuous))
        case .circle:  AnyShape(Ellipse())
        }
    }
}

/// 출력 해상도 (속성 패널의 픽셀 값 표시용)
enum OutputCanvas {
    static var width: CGFloat { VideoQuality.running.size.width }
    static var height: CGFloat { VideoQuality.running.size.height }
}

/// 방송·녹화 화질. 엔진은 앱을 시작할 때 정해진 화질로 돌아간다 (바꾸면 다시 시작)
enum VideoQuality: Int, CaseIterable, Identifiable {
    case hd = 720, fullHD = 1080
    var id: Int { rawValue }
    static var chosen: VideoQuality {
        get { VideoQuality(rawValue: UserDefaults.standard.integer(forKey: "WSVideoQuality")) ?? .hd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "WSVideoQuality") }
    }
    /// 지금 엔진이 쓰는 화질 (앱 시작 때 고정)
    static let running = chosen
    var size: CGSize { self == .fullHD ? CGSize(width: 1920, height: 1080) : CGSize(width: 1280, height: 720) }
    var title: String { self == .fullHD ? "1080p" : "720p" }
    var neededUpMbps: Double { self == .fullHD ? 9 : 5.5 }
}

// MARK: - 루트

struct SceneEditorView: View {
    @Bindable var store: ShowStore
    /// 실제 소스 영상을 그리는 뷰. 엔진에서 주입 (없으면 자리표시)
    var extraInspector: AnyView? = nil
    var compositePreview: AnyView? = nil
    var sourcePreview: (Source) -> AnyView = { AnyView(PlaceholderSourceView(source: $0)) }
    /// 오디오 레벨 (0...1). 엔진에서 주입
    var audioLevel: (Source.ID) -> Float = { _ in 0 }

    @State private var showNewScene = false
    @State private var showAddSource = false
    @AppStorage("editor.leftTab") private var leftTab = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("", selection: $leftTab) {
                    Text("장면").tag(0)
                    Text("미디어").tag(1)
                    Text("그래픽").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                switch leftTab {
                case 1: MediaPanel(store: store).padding(.horizontal, 14).padding(.top, 10)
                case 2: GraphicsPanel(store: store).padding(.horizontal, 14).padding(.top, 10)
                default: SceneListView(store: store) { showNewScene = true }
                }
            }
            .frame(width: 280)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                SceneHeaderView(store: store)
                CanvasStageView(store: store, compositePreview: compositePreview, sourcePreview: sourcePreview)
                AudioMixerView(store: store, level: audioLevel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)

            Divider()

            VStack(spacing: 0) {
                SourceListView(store: store) { showAddSource = true }
                    .frame(maxHeight: 260)
                Divider()
                ItemInspectorView(store: store)
                if let extraInspector { Divider(); extraInspector.padding(12) }
            }
            .frame(width: 340)
        }
        .overlay(alignment: .bottom) {
            UndoRemovalBanner(store: store).padding(.bottom, 18)
                .animation(.spring(duration: 0.3), value: store.lastRemoval?.at)
        }
        .sheet(isPresented: $showNewScene) { NewSceneSheet(store: store) }
        .sheet(isPresented: $showAddSource) { AddSourceSheet(store: store) }
        .onAppear { if store.selectedSceneID == nil { store.selectedSceneID = store.scenes.first?.id } }
        .onChange(of: store.selectedSceneID) { store.selectedItemID = nil }
    }
}

// MARK: - 왼쪽: 장면 목록

struct SceneListView: View {
    @Bindable var store: ShowStore
    var onNew: () -> Void
    @State private var confirmDelete: ShowScene.ID?
    @State private var dropTarget: ShowScene.ID?
    @State private var renaming: ShowScene.ID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    private func commitRename() {
        if let id = renaming {
            let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { store.renameScene(id, to: name) }
        }
        renaming = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("장면").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("드래그로 순서 변경").font(.uiCaption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 14)

            List(selection: $store.selectedSceneID) {
                ForEach(Array(store.scenes.enumerated()), id: \.element.id) { index, scene in
                    HStack(spacing: 10) {
                        SceneThumbnail(scene: scene, store: store)
                            .frame(width: 64, height: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            if renaming == scene.id {
                                TextField("장면 이름", text: $renameDraft)
                                    .textFieldStyle(.roundedBorder).font(.uiBody.weight(.semibold))
                                    .focused($renameFocused)
                                    .onSubmit { commitRename() }
                                    .onExitCommand { renaming = nil }
                                    .onChange(of: renameFocused) { if !renameFocused { commitRename() } }
                            } else {
                                Text(scene.name).font(.uiBody.weight(.semibold))
                                    .onTapGesture(count: 2) { renameDraft = scene.name; renaming = scene.id; renameFocused = true }
                                    .help("더블클릭해서 이름 바꾸기")
                            }
                            HStack(spacing: 4) {
                                Text("소스 \(scene.items.count)개").font(.uiCaption2).foregroundStyle(.secondary)
                                if !store.mainMicOn(in: scene) {
                                    Image(systemName: "mic.slash.fill").font(.system(size: 9)).foregroundStyle(.orange)
                                        .help("이 장면에서는 강단 마이크가 나가지 않습니다")
                                }
                            }
                        }
                        Spacer()
                        if index < 9 { Text("⌘\(index + 1)").font(.uiCaption2).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .sceneReorderable(scene, store: store, dropTarget: $dropTarget)
                    .tag(scene.id)
                    .contextMenu {
                        Button("이름 바꾸기…") { renameDraft = scene.name; renaming = scene.id; renameFocused = true }
                        Button("복제") { store.selectedSceneID = scene.id; store.duplicateSelectedScene() }
                        Button("위로") { store.moveScene(scene.id, by: -1) }.disabled(index == 0)
                        Button("아래로") { store.moveScene(scene.id, by: 1) }.disabled(index == store.scenes.count - 1)
                        if !store.mainMicOn(in: scene) { Button("강단 마이크 켜기") { store.turnOnMainMic(in: scene.id) } }
                        Divider()
                        Button("삭제…", role: .destructive) { confirmDelete = scene.id }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { if let id = store.selectedSceneID { confirmDelete = id } }

            // 선택한 장면 다루기: 새로 · 복제 · 위 · 아래 · 삭제
            HStack(spacing: 6) {
                Button(action: onNew) { Label("새 장면", systemImage: "plus").frame(maxWidth: .infinity) }
                    .help("템플릿에서 새 장면 만들기")
                ListBarButton(symbol: "plus.square.on.square", help: L("선택한 장면 복제")) { store.duplicateSelectedScene() }
                    .disabled(store.selectedSceneID == nil)
                ListBarButton(symbol: "arrow.up", help: L("위로")) { if let id = store.selectedSceneID { store.moveScene(id, by: -1) } }
                    .disabled(store.selectedSceneID == nil || store.scenes.first?.id == store.selectedSceneID)
                ListBarButton(symbol: "arrow.down", help: L("아래로")) { if let id = store.selectedSceneID { store.moveScene(id, by: 1) } }
                    .disabled(store.selectedSceneID == nil || store.scenes.last?.id == store.selectedSceneID)
                ListBarButton(symbol: "trash", help: L("선택한 장면 삭제 (⌫)"), destructive: true) { confirmDelete = store.selectedSceneID }
                    .disabled(store.selectedSceneID == nil)
            }
            .padding(.horizontal, 12)

            Text("여기 순서와 이름이 그대로 진행 모드의 장면 버튼이 됩니다.")
                .font(.uiCaption2).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .background(.background.secondary)
        .confirmationDialog("이 장면을 삭제할까요?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { id in
            Button("장면 삭제", role: .destructive) { store.deleteScene(id); confirmDelete = nil }
            Button("취소", role: .cancel) { confirmDelete = nil }
        } message: { id in
            Text("‘\(store.scenes.first { $0.id == id }?.name ?? "장면")’과 그 안의 배치가 지워집니다. 바로 아래 ‘되돌리기’로 복구할 수 있습니다.")
        }
    }
}

/// 목록 아래 막대의 작은 아이콘 단추 (장면·레이어 공통)
struct ListBarButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 30)
                .foregroundStyle(destructive && enabled ? Color.red : Color.primary)
        }
        .help(L(help))
        .accessibilityLabel(L(help))
    }
}

/// 방금 지운 장면·레이어 되돌리기 (8초 동안, ⌘Z)
struct UndoRemovalBanner: View {
    @Bindable var store: ShowStore
    var body: some View {
        if let removal = store.lastRemoval {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text("\(removal.title)을(를) 지웠습니다").font(.uiCallout).lineLimit(1)
                Button("되돌리기") { store.undoRemoval() }
                    .churchProminentButton()
                    .keyboardShortcut("z", modifiers: .command)
                Button { store.lastRemoval = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("닫기")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .churchGlass(ChurchShape.floating)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .task(id: removal.at) {
                try? await Task.sleep(for: .seconds(8))
                if store.lastRemoval?.at == removal.at { withAnimation { store.lastRemoval = nil } }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 장면 구성을 색 블록으로 보여주는 작은 썸네일
// MARK: - 장면 끌어 놓기 (장면 목록 · 진행 화면 장면 버튼 공용)

extension View {
    /// 장면을 끌어 다른 장면 위에 놓으면 그 자리로 옮긴다. 놓을 자리는 위쪽 파란 선으로 보인다.
    func sceneReorderable(_ scene: ShowScene, store: ShowStore, dropTarget: Binding<ShowScene.ID?>) -> some View {
        self
            .draggable(scene.id.uuidString) {
                Text(scene.name).font(.uiCallout.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: String.self) { ids, _ in
                dropTarget.wrappedValue = nil
                guard let raw = ids.first, let id = UUID(uuidString: raw), id != scene.id,
                      store.scenes.contains(where: { $0.id == id }) else { return false }
                withAnimation(.snappy(duration: 0.2)) { store.reorderScene(id, onto: scene.id) }
                return true
            } isTargeted: { on in
                if on { dropTarget.wrappedValue = scene.id } else if dropTarget.wrappedValue == scene.id { dropTarget.wrappedValue = nil }
            }
            .overlay(alignment: .top) {
                if dropTarget.wrappedValue == scene.id {
                    Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -3).allowsHitTesting(false)
                }
            }
    }
}

struct SceneThumbnail: View {
    let scene: ShowScene
    let store: ShowStore

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(scene.items.filter { $0.isVisible }) { item in
                    if let src = store.source(item.sourceID), src.kind.isVisual {
                        let r = item.frame
                        let size = CGSize(width: r.width * geo.size.width, height: r.height * geo.size.height)
                        src.kind.tint
                            .clipShape(item.shape.shape(in: size))
                            .frame(width: size.width, height: size.height)
                            .rotationEffect(.degrees(item.angle))
                            .offset(x: r.minX * geo.size.width, y: r.minY * geo.size.height)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 가운데 위: 장면 이름 / 전환 / 복제

struct SceneHeaderView: View {
    @Bindable var store: ShowStore

    /// 선택지: nil = 기본
    private let choices: [SceneTransition?] = [
        nil,
        SceneTransition(style: .cut, duration: 0),
        SceneTransition(style: .fade, duration: 0.5),
        SceneTransition(style: .fade, duration: 1.0),
        SceneTransition(style: .slide, duration: 0.5),
    ]

    private func label(_ t: SceneTransition?) -> String {
        guard let t else {
            let d = store.defaultTransition
            return "기본 (\(d.style.title)\(d.style == .cut ? "" : " \(d.duration.formatted())초"))"
        }
        return t.style == .cut ? "컷" : "\(t.style.title) \(t.duration.formatted())초"
    }

    var body: some View {
        if let i = store.selectedSceneIndex {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                        TextField("장면 이름", text: $store.scenes[i].name)
                            .textFieldStyle(.roundedBorder).font(.uiTitle3.bold()).frame(maxWidth: 260)
                            .help("장면 이름을 바꾸려면 여기를 누르고 입력하세요")
                    }
                    Spacer()
                    Button("장면 복제") { store.duplicateSelectedScene() }
                }
                HStack {
                    Text("\(Int(OutputCanvas.width)) × \(Int(OutputCanvas.height)) · 드래그로 위치·크기 조절").font(.uiCaption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("이 장면으로 전환", selection: $store.scenes[i].transitionIn) { ForEach(choices, id: \.self) { Text(label($0)).tag($0) } }.frame(width: 210)
                }
            }
        } else {
            Text("장면을 선택하거나 새로 만드세요").foregroundStyle(.secondary)
        }
    }
}

// 캔버스 편집기는 CanvasEditor.swift (CanvasStageView)

/// 엔진 연결 전 자리표시
struct PlaceholderSourceView: View {
    let source: Source
    var body: some View {
        ZStack {
            source.kind.tint
            VStack(spacing: 6) {
                Image(systemName: source.kind.symbol).font(.uiTitle2)
                Text(source.name).font(.uiCaption)
            }
            .foregroundStyle(source.kind.accent)
        }
    }
}

// MARK: - 가운데 아래: 이 장면의 오디오

struct AudioMixerView: View {
    @Bindable var store: ShowStore
    var level: (Source.ID) -> Float

    var body: some View {
        let audioItems = store.selectedScene?.items.filter {
            guard let s = store.source($0.sourceID) else { return false }
            if case .window(_, _, _, true) = s.config { return true }   // 앱 소리 캡처 켠 윈도우
            if case .youtube = s.config { return true }
            if case let .media(path, _, audioOnly) = s.config {
                return audioOnly || MediaType.of(URL(fileURLWithPath: path)) == .video
            }
            return s.kind == .audio
        } ?? []

        VStack(alignment: .leading, spacing: 8) {
            Text("이 장면의 오디오").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
            if let scene = store.selectedScene, !store.mainMicOn(in: scene) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.orange).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("강단 마이크가 이 장면에서 나가지 않습니다").font(.uiCallout.weight(.semibold))
                        Text("대기·종료 화면처럼 일부러 끈 경우가 아니라면 켜 주세요.").font(.uiCaption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("마이크 켜기") { store.turnOnMainMic(in: scene.id) }.churchProminentButton()
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
            }
            if audioItems.isEmpty && store.mainMicSourceID == nil {
                Text("오디오 소스가 없습니다. 소스 추가 › 오디오 캡처").font(.uiCaption).foregroundStyle(.tertiary)
            }
            ForEach(audioItems) { item in
                if let src = store.source(item.sourceID) {
                    HStack(spacing: 12) {
                        Image(systemName: src.kind.symbol).frame(width: 18)
                        Text(src.name).frame(width: 150, alignment: .leading).lineLimit(1)
                        LevelMeter(value: item.isMuted ? 0 : level(src.id) * item.volume, showsDB: true)
                        Slider(value: Binding(get: { Double(item.volume) },
                                              set: { v in store.updateItem(item.id) { $0.volume = Float(v) } }),
                               in: 0...1)
                            .frame(width: 110)
                        Button {
                            store.updateItem(item.id) { $0.isMuted.toggle() }
                        } label: {
                            Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        .help(item.isMuted ? L("음소거 해제") : L("음소거"))
                        .accessibilityLabel("\(src.name) 음소거")
                        if store.hasPlayableAudio(src) { AudioRoutePicker(store: store, source: src).controlSize(.small) }
                    }
                    if store.isPlayable(src) {
                        MediaTransportBar(store: store, source: src).padding(.leading, 30).padding(.bottom, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: ChurchShape.button))
    }
}

/// 소리 막대. 엔진 값은 선형 진폭(0~1)이라 그대로 그리면 말소리(-20dB ≈ 0.1)가 거의 안 보인다.
/// 방송 장비처럼 dB 눈금(-60 ~ 0 dB)으로 바꿔 칸으로 그린다: 초록(~-18) · 노랑(~-6) · 빨강(0 근처 = 찌그러짐 위험).
/// 빨리 오르고 천천히 내려가며, 최고점은 1.5초 동안 남는다.
struct LevelMeter: View {
    var value: Float           // 선형 0...1
    var segments = 30
    var height: CGFloat = 10
    var showsDB = false

    @State private var shown: Double = 0
    @State private var peak: Double = 0
    @State private var peakAt = Date.distantPast
    @State private var peakDB: Double = -60

    static let floorDB = -60.0
    static func fraction(_ linear: Float) -> Double {
        guard linear > 0.000_01 else { return 0 }
        let db = 20 * log10(Double(linear))
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }
    private static let yellowAt = (-18.0 - floorDB) / -floorDB   // 0.7
    private static let redAt = (-6.0 - floorDB) / -floorDB       // 0.9

    private func color(_ position: Double) -> Color {
        position >= Self.redAt ? Color(red: 1.0, green: 0.27, blue: 0.23)
            : position >= Self.yellowAt ? Color(red: 1.0, green: 0.80, blue: 0.20)
            : ChurchStatus.ok
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let w = max((geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments), 1)
                let peakIndex = Int((peak * Double(segments)).rounded(.up)) - 1
                HStack(spacing: gap) {
                    ForEach(0..<segments, id: \.self) { i in
                        let position = (Double(i) + 0.5) / Double(segments)
                        let lit = position <= shown
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(position).opacity(lit ? 1 : (i == peakIndex && peak > 0.02 ? 0.9 : 0.14)))
                            .frame(width: w)
                    }
                }
            }
            .frame(height: height)
            if showsDB {
                Text(peakDB <= Self.floorDB + 0.5 ? "−∞" : String(format: "%.0f", peakDB))
                    .font(.uiCaption2.monospacedDigit())
                    .foregroundStyle(peak >= Self.redAt ? Color.red : .secondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .animation(.linear(duration: 0.12), value: shown)
        .onChange(of: value, initial: true) { _, newValue in
            let f = Self.fraction(newValue)
            shown = f > shown ? f : max(f, shown - 0.05)          // 빨리 오르고 천천히 내려감
            let now = Date()
            if f >= peak || now.timeIntervalSince(peakAt) > 1.5 {
                peak = f; peakAt = now
                peakDB = f <= 0 ? Self.floorDB : f * -Self.floorDB + Self.floorDB
            }
        }
        .accessibilityLabel("소리 크기")
        .accessibilityValue(peakDB <= Self.floorDB + 0.5 ? "소리 없음" : "\(Int(peakDB)) 데시벨")
    }
}

// MARK: - 오른쪽 위: 소스 목록 (위가 앞)

struct SourceListView: View {
    @Bindable var store: ShowStore
    var onAdd: () -> Void
    @State private var dropTarget: SceneItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("소스 · 위가 앞 · 끌어서 순서 변경").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) { Label("소스 추가", systemImage: "plus") }
                    .churchProminentButton()
                    .controlSize(.regular)
                    .disabled(store.selectedScene == nil)
            }
            .padding(.horizontal, 14).padding(.top, 12)

            let display = Array((store.selectedScene?.items ?? []).reversed())
            List(selection: $store.selectedItemID) {
                ForEach(display) { item in
                    if let src = store.source(item.sourceID) {
                        HStack(spacing: 10) {
                            Image(systemName: src.kind.symbol).foregroundStyle(src.kind.accent).frame(width: 18)
                            Text(src.name).lineLimit(1)
                            Text(isShared(src) ? "\(src.kind.title) · 공유됨" : src.kind.title)
                                .font(.uiCaption2).foregroundStyle(.secondary)
                            if let warning = store.sourceWarnings[src.id] {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(warning)
                                    .accessibilityLabel("문제: \(warning)")
                            }
                            Spacer()
                            if src.kind.isVisual {
                                Button { store.updateItem(item.id) { $0.isVisible.toggle() } } label: {
                                    Image(systemName: item.isVisible ? "eye" : "eye.slash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(item.isVisible ? L("숨기기") : L("보이기"))
                                Button { store.updateItem(item.id) { $0.isLocked.toggle() } } label: {
                                    Image(systemName: item.isLocked ? "lock" : "lock.open")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(item.isLocked ? L("잠금 해제") : L("잠그기"))
                            }
                        }
                        .contentShape(Rectangle())
                        .draggable("layer:" + item.id.uuidString) {
                            Label(src.name, systemImage: src.kind.symbol).font(.uiCallout.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            dropTarget = nil
                            guard let raw = ids.first, raw.hasPrefix("layer:"), let id = UUID(uuidString: String(raw.dropFirst(6))),
                                  id != item.id else { return false }
                            withAnimation(.snappy(duration: 0.2)) { store.reorderItem(id, onto: item.id) }
                            return true
                        } isTargeted: { on in
                            if on { dropTarget = item.id } else if dropTarget == item.id { dropTarget = nil }
                        }
                        .overlay(alignment: .top) {
                            if dropTarget == item.id {
                                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -3).allowsHitTesting(false)
                            }
                        }
                        .tag(item.id)
                        .contextMenu {
                            Button("맨 앞으로") { store.reorder(item.id, .front) }
                            Button("앞으로  ⌘]") { store.reorder(item.id, .forward) }
                            Button("뒤로  ⌘[") { store.reorder(item.id, .backward) }
                            Button("맨 뒤로") { store.reorder(item.id, .back) }
                            Divider()
                            if src.kind.isVisual { Button("복제") { store.selectedItemID = item.id; store.duplicateItem(item.id) } }
                            Button(item.isLocked ? L("잠금 해제") : L("잠그기")) { store.updateItem(item.id) { $0.isLocked.toggle() } }
                            Divider()
                            Button("이 장면에서 지우기", role: .destructive) { store.removeItem(item.id) }
                        }
                    }
                }
                .onDelete { idx in idx.map { display[$0].id }.forEach(store.removeItem) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { if let id = store.selectedItemID { store.removeItem(id) } }

            // 선택한 레이어 다루기 (위가 앞): 앞으로 · 뒤로 · 복제 · 지우기
            let selected = store.selectedItem
            let isTop = selected != nil && display.first?.id == selected?.id
            let isBottom = selected != nil && display.last?.id == selected?.id
            HStack(spacing: 6) {
                ListBarButton(symbol: "arrow.up", help: L("앞으로 (목록에서 위로) ⌘]")) { if let id = selected?.id { store.reorder(id, .forward) } }
                    .disabled(selected == nil || isTop)
                ListBarButton(symbol: "arrow.down", help: L("뒤로 (목록에서 아래로) ⌘[")) { if let id = selected?.id { store.reorder(id, .backward) } }
                    .disabled(selected == nil || isBottom)
                ListBarButton(symbol: "arrow.up.to.line", help: L("맨 앞으로")) { if let id = selected?.id { store.reorder(id, .front) } }
                    .disabled(selected == nil || isTop)
                ListBarButton(symbol: "plus.square.on.square", help: L("복제 ⌘D")) { if let id = selected?.id { store.duplicateItem(id) } }
                    .disabled(selected == nil || !(selected.flatMap { store.source($0.sourceID) }?.kind.isVisual ?? false))
                Spacer()
                ListBarButton(symbol: "trash", help: L("이 장면에서 지우기 (⌫)"), destructive: true) { if let id = selected?.id { store.removeItem(id) } }
                    .disabled(selected == nil)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func isShared(_ src: Source) -> Bool {
        store.scenes.filter { $0.items.contains { $0.sourceID == src.id } }.count > 1
    }
}

// MARK: - 오른쪽 아래: 속성

struct ItemInspectorView: View {
    @Bindable var store: ShowStore

    var body: some View {
        ScrollView {
            if let item = store.selectedItem, let src = store.source(item.sourceID) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("속성 · \(src.name)").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                    if let warning = store.sourceWarnings[src.id] {
                        if warning.contains("화면 녹화") || warning.localizedCaseInsensitiveContains("screen recording") {
                            ScreenPermissionNotice(compact: true)
                        } else {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.uiCaption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    TextField("소스 이름", text: Binding(get: { src.name },
                                                       set: { v in store.updateSource(src.id) { $0.name = v } }))

                    SourceConfigEditor(store: store, source: src)

                    if src.kind.isVisual {
                        layoutSection(item)
                    }

                }
                .padding(16)
            } else {
                Text("캔버스나 목록에서 소스를 선택하세요")
                    .font(.uiCaption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
    }

    @ViewBuilder
    private func layoutSection(_ item: SceneItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("빠른 배치").font(.uiCaption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48, maximum: 56), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(PlacementPreset.allCases) { p in
                    Button { store.apply(p, to: item.id) } label: {
                        PresetGlyph(preset: p, active: item.frame == p.frame)
                    }
                    .buttonStyle(.plain)
                    .help(p.title)
                    .accessibilityLabel(p.title)
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("화면 기준 정렬").font(.uiCaption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(CanvasAlign.allCases, id: \.self) { a in
                    Button { store.align(item.id, a) } label: { Image(systemName: a.symbol).frame(width: 30, height: 24) }
                        .churchButton()
                        .help("\(a.title) 맞춤")
                        .accessibilityLabel("\(a.title) 맞춤")
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("회전").font(.uiCaption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("각도", value: Binding(get: { item.angle.rounded() },
                                                set: { v in store.rotate(item.id, to: v) }),
                          format: .number)
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("°").foregroundStyle(.secondary)
                Button { store.rotate(item.id, to: item.angle - 90) } label: { Image(systemName: "rotate.left") }
                    .help("왼쪽으로 90°")
                Button { store.rotate(item.id, to: item.angle + 90) } label: { Image(systemName: "rotate.right") }
                    .help("오른쪽으로 90°")
                Button("0°") { store.rotate(item.id, to: 0) }
                    .disabled(item.angle == 0)
            }
            .controlSize(.regular)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("자르기").font(.uiCaption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { store.cropRequest = item.id } label: { Label("자르기", systemImage: "crop") }
                    .disabled(item.angle != 0)
                    .help(item.angle != 0 ? L("회전을 0°로 되돌리면 자를 수 있습니다") : L("자르기 모드"))
                Button("초기화") { store.resetCrop(item.id) }
                    .disabled(item.crop == .zero)
                Button("화면에 맞춤") { store.fitFrameToContent(item.id) }
                    .help("상자를 실제 화면 비율에 맞춰 위아래·좌우 빈 띠를 없앱니다")
            }
            .controlSize(.regular)
            if item.crop != .zero {
                Text("왼 \(pct(item.crop.left)) · 위 \(pct(item.crop.top)) · 오른 \(pct(item.crop.right)) · 아래 \(pct(item.crop.bottom))")
                    .font(.uiCaption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }

        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                pixelField("X", item, \.origin.x, scale: OutputCanvas.width)
                pixelField("Y", item, \.origin.y, scale: OutputCanvas.height)
            }
            GridRow {
                pixelField("너비", item, \.size.width, scale: OutputCanvas.width)
                pixelField("높이", item, \.size.height, scale: OutputCanvas.height)
            }
        }

        Picker("모양", selection: Binding(get: { item.shape },
                                         set: { v in store.setShape(item.id, v) })) {
            ForEach(ItemShape.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(!store.supportsShapes)

        Toggle("테두리", isOn: Binding(get: { item.hasBorder },
                                     set: { v in store.updateItem(item.id) { $0.hasBorder = v } }))
        .disabled(!store.supportsShapes)
        if store.supportsShapes {
            Text(item.shape == .circle ? L("원: 가운데를 정사각형으로 잘랐습니다. 더블클릭해 보이는 부분을 옮길 수 있습니다.")
                 : L("모양과 테두리는 송출 화면에 그대로 나갑니다."))
                .font(.uiCaption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !store.supportsShapes {
            Text("현재 출력은 사각 레이어입니다.").font(.uiCaption2).foregroundStyle(.secondary)
            if item.shape != .rect || item.hasBorder { Button("사각 레이어로 변경") { store.updateItem(item.id) { $0.shape = .rect; $0.hasBorder = false } } }
        }
    }

    private func pct(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }

    private func pixelField(_ title: String, _ item: SceneItem,
                            _ kp: WritableKeyPath<CGRect, CGFloat>, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(title)).font(.uiCaption2).foregroundStyle(.secondary)
            TextField(title, value: Binding(
                get: { Double((item.frame[keyPath: kp] * scale).rounded()) },
                set: { v in store.updateItem(item.id) { $0.frame[keyPath: kp] = CGFloat(v) / scale } }
            ), format: .number)
            .monospacedDigit()
        }
    }
}

/// 빠른 배치 버튼 아이콘
private struct PresetGlyph: View {
    let preset: PlacementPreset
    let active: Bool
    var body: some View {
        GeometryReader { geo in
            let inner = geo.size.applying(.init(scaleX: 0.78, y: 0.7))
            let f = preset.frame
            RoundedRectangle(cornerRadius: 1.5)
                .fill(active ? Color.accentColor : Color.secondary)
                .frame(width: max(f.width * inner.width, 4), height: max(f.height * inner.height, 3))
                .offset(x: (geo.size.width - inner.width) / 2 + f.minX * inner.width,
                        y: (geo.size.height - inner.height) / 2 + f.minY * inner.height)
        }
        .frame(width: 48, height: 32)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: ChurchShape.badge))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.badge).strokeBorder(active ? Color.accentColor : .clear))
    }
}

/// 추가 카메라만의 보정·색 톤·배경 흐림. 끄면 준비 화면의 공통 설정을 따른다
struct CameraLookEditor: View {
    @Bindable var store: ShowStore
    let source: Source

    private func set(_ change: @escaping (inout CameraLook) -> Void) {
        store.updateSource(source.id) { s in
            var look = s.look ?? CameraLook()
            change(&look)
            s.look = look
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("이 카메라만 따로 설정", isOn: Binding(
                get: { source.look != nil },
                set: { on in store.updateSource(source.id) { $0.look = on ? CameraLook() : nil } }))
            .disabled(!store.isPro)
            if !store.isPro {
                Label("카메라별 보정·색 톤은 Pro 기능입니다", systemImage: "lock.fill").font(.uiCaption2).foregroundStyle(.secondary)
            }
            if let look = source.look, store.isPro {
                Text("자연 보정").font(.uiCaption).foregroundStyle(.secondary)
                Picker("자연 보정", selection: Binding(get: { look.beauty }, set: { v in set { $0.beauty = v } })) {
                    Text("끔").tag(0); Text("자연스럽게").tag(1); Text("조금 더").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                Text("색 톤").font(.uiCaption).foregroundStyle(.secondary)
                Picker("색 톤", selection: Binding(get: { look.tone }, set: { v in set { $0.tone = v } })) {
                    Text("원본").tag(0); Text("따뜻").tag(1); Text("맑게").tag(2); Text("차분").tag(3); Text("필름").tag(4)
                }.pickerStyle(.segmented).labelsHidden()
                if look.tone != 0 {
                    HStack {
                        Text("톤 강도").font(.uiCaption).frame(width: 60, alignment: .leading)
                        Slider(value: Binding(get: { look.toneAmount }, set: { v in set { $0.toneAmount = v } }), in: 0...100)
                    }
                }
                HStack {
                    Text("배경 흐림").font(.uiCaption).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { look.blur }, set: { v in set { $0.blur = v } }), in: 0...100)
                    Text(look.blur > 0 ? "\(Int(look.blur))" : "끔").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                }
            } else if store.isPro {
                Text("지금은 준비 화면의 자연 보정·색 톤을 그대로 씁니다.").font(.uiCaption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button))
    }
}

/// 영상·음악 소리가 나가는 곳: 방송+현장 · 방송만 · 현장만 (진행 중에도 바꿀 수 있음)
struct AudioRoutePicker: View {
    @Bindable var store: ShowStore
    let source: Source

    var body: some View {
        let current = store.source(source.id)?.effectiveAudioRoute ?? source.effectiveAudioRoute
        Picker("소리 나가는 곳", selection: Binding(get: { current }, set: { store.setAudioRoute(source.id, $0) })) {
            ForEach(AudioRoute.allCases) { route in
                Label(route.title, systemImage: route.symbol).tag(route)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(current.help)
        .accessibilityLabel("\(source.name) 소리 나가는 곳")
    }
}

/// 영상 재생 막대: 재생/멈춤 · 처음부터 · 정지 · 진행 시간 · 반복 (진행 중에도 쓸 수 있다)
struct MediaTransportBar: View {
    @Bindable var store: ShowStore
    let source: Source
    @State private var players = YouTubePlayers.shared

    private static func clock(_ ms: Double) -> String {
        let s = max(Int(ms / 1000), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        let current = store.source(source.id) ?? source
        let looping = store.isLooping(current)
        let isTube = current.kind == .youtube
        let state = store.mediaStates[source.id]
        let playing = isTube ? !players.isPaused(source.id) : (state?.isPlaying ?? false)
        HStack(spacing: 8) {
            Button { store.mediaControl(source.id, playing ? "pause" : "play") } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(playing ? L("멈춤") : L("재생"))
            Button { store.mediaControl(source.id, "restart") } label: { Image(systemName: "backward.end.fill") }
                .help("처음부터")
            if !isTube {
                Button { store.mediaControl(source.id, "stop") } label: { Image(systemName: "stop.fill") }
                    .help("정지")
            }
            if let state, state.duration > 0, !isTube {
                ProgressView(value: min(state.time, state.duration), total: state.duration)
                    .progressViewStyle(.linear).frame(minWidth: 60)
                Text(Self.clock(state.time) + " / " + Self.clock(state.duration))
                    .font(.uiCaption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            } else {
                Text(isTube ? (players.status[source.id] ?? L("송출 장면에 들어가면 재생됩니다")) : stateText(state))
                    .font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Toggle(isOn: Binding(get: { looping }, set: { store.setMediaLoop(source.id, $0) })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help(looping ? L("반복 재생 켜짐 · 누르면 한 번만 재생") : L("한 번만 재생 · 누르면 반복"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func stateText(_ state: MediaPlayState?) -> String {
        switch state?.state ?? 0 {
        case 1: L("재생 중")
        case 2, 3: L("불러오는 중…")
        case 4: L("멈춤")
        case 5: L("정지")
        case 6: L("끝남")
        case 7: L("재생하지 못했습니다")
        default: L("송출 장면에 들어가면 재생됩니다")
        }
    }
}

/// 진행 화면: 지금 송출 중·다음 장면의 영상·음악 소리를 바로 바꾸는 줄
struct LiveMediaSoundBar: View {
    @Bindable var store: ShowStore

    private func playable(_ sceneID: ShowScene.ID?) -> [Source] {
        guard let scene = store.scenes.first(where: { $0.id == sceneID }) else { return [] }
        var seen = Set<Source.ID>()
        return scene.items.compactMap { item in
            guard item.isVisible, let src = store.source(item.sourceID), store.hasPlayableAudio(src), seen.insert(src.id).inserted else { return nil }
            return src
        }
    }

    var body: some View {
        let live = playable(store.programSceneID)
        let next = store.previewSceneID == store.programSceneID ? [] : playable(store.previewSceneID).filter { s in !live.contains { $0.id == s.id } }
        if !live.isEmpty || !next.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(live) { row($0, badge: L("송출 중"), tint: .red) }
                ForEach(next) { row($0, badge: L("다음"), tint: ChurchStatus.ok) }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
        }
    }

    private func row(_ src: Source, badge: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Text(badge).font(.uiCaption2.weight(.bold)).foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule())
            Image(systemName: { if case .media(_, _, true) = src.config { return "music.note" }; return src.kind == .youtube ? "play.rectangle.fill" : "film" }())
                .foregroundStyle(.secondary)
            Text(src.name).font(.uiCallout).lineLimit(1)
            Spacer(minLength: 8)
            AudioRoutePicker(store: store, source: src).controlSize(.small)
        }
            MediaTransportBar(store: store, source: src).padding(.leading, 4)
        }
    }
}

/// 유튜브 소스 속성: 주소 · 반복 · 상태 · 처음부터/멈춤 · 소리 나가는 곳
struct YouTubeSourceEditor: View {
    @Bindable var store: ShowStore
    let source: Source
    let url: String
    let loop: Bool
    @State private var draft = ""
    @State private var players = YouTubePlayers.shared

    var body: some View {
        let id = YouTubeLink.videoID(url)
        VStack(alignment: .leading, spacing: 8) {
            if let id, let thumb = YouTubeLink.thumbnail(id) {
                AsyncImage(url: thumb) { image in image.resizable().aspectRatio(16 / 9, contentMode: .fill) } placeholder: { Color.black }
                    .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            TextField("유튜브 주소", text: $draft, prompt: Text("https://youtu.be/…"))
                .onSubmit { commit() }
                .onAppear { draft = url }
                .onChange(of: url) { draft = url }
            if !draft.isEmpty && YouTubeLink.videoID(draft) == nil {
                Text("유튜브 영상 주소가 아닙니다.").font(.uiCaption2).foregroundStyle(.orange)
            } else if draft != url {
                Button("이 주소로 바꾸기") { commit() }.controlSize(.small)
            }
            Toggle("끝나면 처음부터 반복", isOn: Binding(get: { loop }, set: { v in store.updateSource(source.id) { $0.config = .youtube(url: url, loop: v) } }))
            HStack(spacing: 8) {
                Text(players.status[source.id] ?? L("송출 장면에 들어가면 재생됩니다")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { players.restart(source.id) } label: { Image(systemName: "backward.end.fill") }.help("처음부터")
                Button { players.togglePause(source.id) } label: { Image(systemName: players.isPaused(source.id) ? "play.fill" : "pause.fill") }.help("재생 / 멈춤")
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("소리 나가는 곳").font(.uiCaption.weight(.semibold))
                AudioRoutePicker(store: store, source: source)
                Text(source.effectiveAudioRoute.help).font(.uiCaption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("송출 장면에 들어가면 처음부터 재생되고, 다른 장면으로 바꾸면 멈춥니다. 수익 창출 영상은 광고가 나올 수 있고, 퍼가기를 막은 영상은 재생되지 않습니다.")
                .font(.uiCaption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit() {
        guard YouTubeLink.videoID(draft) != nil, draft != url else { return }
        store.updateSource(source.id) { $0.config = .youtube(url: draft, loop: loop) }
    }
}

/// 소스 종류별 설정
struct SourceConfigEditor: View {
    @Bindable var store: ShowStore
    let source: Source
    @State private var showWindowPicker = false
    @State private var pickedWindow: SCWindow?

    var body: some View {
        switch source.config {
        case let .text(value, opaque):
            if let style = source.textStyle {
                TextObjectEditor(store: store, source: source, value: value, style: style)
            } else {
                TextEditor(text: Binding(get: { value }, set: { v in store.updateSource(source.id) { $0.config = .text(value: v, opaque: opaque) } }))
                    .frame(minHeight: 100)
                Button("글자를 움직일 수 있게 바꾸기") { store.migrateLegacyText(); store.refreshPreview() }
                    .help("화면 전체에 그려진 문구를 글자 오브젝트로 바꿉니다. 배경이 있으면 따로 배경 레이어가 생깁니다.")
            }
        case let .media(path, loop, audioOnly):
            Text(path.isEmpty ? L("파일을 선택하세요") : URL(fileURLWithPath: path).lastPathComponent).font(.uiCaption)
            Button("파일 선택…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    store.updateSource(source.id) { $0.config = .media(path: url.path, loop: loop, audioOnly: audioOnly) }
                }
            }
            Toggle("반복 재생", isOn: Binding(get: { loop }, set: { v in store.updateSource(source.id) { $0.config = .media(path: path, loop: v, audioOnly: audioOnly) } }))
            if store.hasPlayableAudio(source) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("소리 나가는 곳").font(.uiCaption.weight(.semibold))
                    AudioRoutePicker(store: store, source: source)
                    Text(source.effectiveAudioRoute.help).font(.uiCaption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .graphic(icon, color, _):
            HStack(spacing: 8) {
                Image(systemName: "star.square.on.square").foregroundStyle(.secondary)
                Text(icon).font(.uiCaption.monospaced()).lineLimit(1)
            }
            ColorPicker("색", selection: Binding(get: { Color(hex: color) }, set: { newColor in
                let hex = newColor.hexString
                guard hex != color, let ref = IconRef(id: icon) else { return }
                Task { @MainActor in
                    if let result = try? await IconLibrary.shared.rasterize(ref, colorHex: hex) {
                        store.updateSource(source.id) { $0.config = .graphic(icon: icon, color: hex, path: result.url.path) }
                    }
                }
            }), supportsOpacity: false)
        case let .camera(device):
            if source.id == store.mainCameraSourceID {
                Text("준비 화면에서 연결한 보정 카메라를 공유합니다.").font(.uiCaption).foregroundStyle(.secondary)
            } else {
                Picker("카메라", selection: Binding(get: { device }, set: { v in store.updateSource(source.id) { $0.config = .camera(deviceID: v) } })) {
                    Text("준비 화면의 보정 카메라").tag(String?.none)
                    ForEach(store.cameraDevices.filter { $0.id != store.mainCameraDeviceID }) { Text($0.name).tag(String?.some($0.id)) }
                }
                if device != nil { CameraLookEditor(store: store, source: source) }
            }
        case let .audio(device, app):
            if source.id == store.mainMicSourceID {
                Text("준비 화면에서 연결한 마이크를 공유합니다.").font(.uiCaption).foregroundStyle(.secondary)
            } else {
                Picker("오디오 입력", selection: Binding(get: { device }, set: { v in store.updateSource(source.id) { $0.config = .audio(deviceID: v, appBundleID: app) } })) {
                    Text("준비 화면의 마이크").tag(String?.none)
                    ForEach(store.microphoneDevices.filter { $0.id != store.mainMicDeviceID }) { Text($0.name).tag(String?.some($0.id)) }
                }
                Text("음량 막대는 아래 ‘이 장면의 오디오’에 표시됩니다.").font(.uiCaption2).foregroundStyle(.secondary)
            }
        case let .captions(showSource, background, fontSize, lines):
            CaptionsStatusRow()
            if WordaliveFeed.shared.styleActive {
                Label("글꼴·크기·색·줄 수는 WORDaLIVE 스튜디오의 자막 설정을 그대로 따릅니다. 바꾸려면 WORDaLIVE 스튜디오 › 자막 설정에서 바꾸세요.", systemImage: "link")
                    .font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("원문도 함께 보이기", isOn: Binding(get: { showSource }, set: { v in store.updateSource(source.id) { $0.config = .captions(showSource: v, background: background, fontSize: fontSize, lines: lines) } }))
            Toggle("자막 띠 배경", isOn: Binding(get: { background }, set: { v in store.updateSource(source.id) { $0.config = .captions(showSource: showSource, background: v, fontSize: fontSize, lines: lines) } }))
            LabeledContent("글자 크기") {
                Slider(value: Binding(get: { Double(fontSize) }, set: { v in store.updateSource(source.id) { $0.config = .captions(showSource: showSource, background: background, fontSize: Int(v), lines: lines) } }), in: 32...96, step: 4)
            }
            .disabled(WordaliveFeed.shared.styleActive)
            Picker("보이는 문장", selection: Binding(get: { lines }, set: { v in store.updateSource(source.id) { $0.config = .captions(showSource: showSource, background: background, fontSize: fontSize, lines: v) } })) {
                Text("1문장").tag(1); Text("2문장").tag(2); Text("상자형").tag(3)
            }.pickerStyle(.segmented)
        case let .screen(displayID, _):
            KeyColorRow(store: store, source: source)
            let displays = DisplayChoice.current()
            Picker("모니터", selection: Binding(get: { displayID }, set: { v in
                let picked = displays.first { $0.id == v }
                store.updateSource(source.id) { $0.config = .screen(displayID: v, name: picked?.name) }
            })) {
                if displayID != nil && !displays.contains(where: { $0.id == displayID }) { Text("연결되지 않은 모니터").tag(displayID) }
                ForEach(displays) { d in Text(d.name + (d.isMain ? " · " + L("주 화면") : "")).tag(String?.some(d.id)) }
            }
            Text("프로젝터·두 번째 모니터에 띄운 PowerPoint 슬라이드 쇼나 ProPresenter 청중 화면을 그대로 가져옵니다.")
                .font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .slides:
            CaptionsStatusRow()
            Text("WORDaLIVE 스튜디오에서 다음 슬라이드로 넘기면 이 자리의 그림도 함께 바뀝니다. 스튜디오의 ‘OBS로 보내기’를 켜 두세요.")
                .font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case let .youtube(url, loop):
            YouTubeSourceEditor(store: store, source: source, url: url, loop: loop)
        case let .browser(url, transparent, w, h):
            TextField("URL", text: Binding(
                get: { url?.absoluteString ?? "" },
                set: { v in store.updateSource(source.id) { $0.config = .browser(url: URL(string: v), transparentBackground: transparent, width: w, height: h) } }
            ))
            Toggle("투명 배경", isOn: Binding(
                get: { transparent },
                set: { v in store.updateSource(source.id) { $0.config = .browser(url: url, transparentBackground: v, width: w, height: h) } }
            ))

        case let .window(bundleID, title, crop, appAudio):
            KeyColorRow(store: store, source: source)
            LabeledContent("대상 창", value: title ?? bundleID ?? L("선택 안 됨"))
            Button("자료 창 선택·변경…") { pickedWindow = nil; showWindowPicker = true }
                .sheet(isPresented: $showWindowPicker) {
                    VStack(spacing: 16) {
                        WindowPickerGrid(selection: $pickedWindow)
                        HStack {
                            Spacer()
                            Button("취소") { showWindowPicker = false }
                            Button("이 창 사용") {
                                if let window = pickedWindow {
                                    store.runtimeWindowIDs[source.id] = window.windowID
                                    store.updateSource(source.id) { $0.config = .window(bundleID: window.owningApplication?.bundleIdentifier, windowTitle: window.title, cropChrome: false, captureAppAudio: false) }
                                }
                                showWindowPicker = false
                            }.disabled(pickedWindow == nil).churchProminentButton()
                        }
                    }.padding(22).frame(width: 800, height: 620)
                }

            Toggle("제목줄 자동 제거 · 준비 중", isOn: Binding(
                get: { false },
                set: { v in store.updateSource(source.id) { $0.config = .window(bundleID: bundleID, windowTitle: title, cropChrome: v, captureAppAudio: appAudio) } }
            )).disabled(true)
            Toggle("이 앱의 소리도 함께 캡처", isOn: Binding(
                get: { appAudio },
                set: { v in store.updateSource(source.id) { $0.config = .window(bundleID: bundleID, windowTitle: title, cropChrome: crop, captureAppAudio: v) } }
            ))
            .disabled(!store.supportsAppAudio)
        }
    }
}

struct DevicePicker: View {
    let title: String
    let devices: [StudioDeviceChoice]
    let selection: String?
    let onChange: (String?) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: onChange)) {
            Text("기본 장치").tag(String?.none)
            ForEach(devices, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
        }
    }
}

enum DeviceCatalog {
    static func cameras() -> [StudioDeviceChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { StudioDeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func microphones() -> [StudioDeviceChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified)
            .devices.map { StudioDeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
}


/// 가져온 자료의 배경을 투명하게 (OBS 컬러 키를 켜고 끄기만)
struct KeyColorRow: View {
    @Bindable var store: ShowStore
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("배경 투명하게", isOn: Binding(get: { source.keyColor != nil }, set: { on in
                store.updateSource(source.id) { $0.keyColor = on ? ($0.keyColor ?? "black") : nil }
            }))
            if let key = source.keyColor {
                Picker("뺄 배경색", selection: Binding(get: { key }, set: { v in store.updateSource(source.id) { $0.keyColor = v } })) {
                    Text("검정").tag("black"); Text("흰색").tag("white"); Text("초록").tag("green")
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("슬라이드 배경이 검정이나 흰색 한 가지 색이면 글자만 남고 뒤로 카메라가 비칩니다. 사진이 많은 슬라이드에는 맞지 않습니다.")
                    .font(.uiCaption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
