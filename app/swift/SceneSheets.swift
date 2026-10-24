// SceneSheets.swift
// churchobs — "새 장면 (템플릿)" 시트, "소스 추가" 시트
// macOS 14+ (ScreenCaptureKit 썸네일은 SCScreenshotManager 사용)

import SwiftUI
import AppKit
import ScreenCaptureKit

// MARK: - 새 장면

struct NewSceneSheet: View {
    @Bindable var store: ShowStore
    @Environment(\.dismiss) private var dismiss

    @State private var template: SceneTemplate = .sermon
    @State private var name: String = SceneTemplate.sermon.name
    @State private var nameEdited = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("새 장면 만들기").font(.uiTitle2.weight(.bold))
                Text("템플릿을 고르면 소스가 미리 배치됩니다. 만든 뒤에는 소스를 자유롭게 추가·이동·삭제할 수 있어요.")
                    .font(.uiCallout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 28)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(SceneTemplate.all) { t in
                    TemplateCard(template: t, selected: t == template)
                        .onTapGesture {
                            template = t
                            if !nameEdited { name = uniqueName(t.name) }
                        }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(28)

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("장면 이름").font(.uiCaption).foregroundStyle(.secondary)
                    TextField("장면 이름", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .textFieldStyle(.roundedBorder)
                }
                Text("카메라·마이크는 1 준비에서 연결한 장치를 자동으로 씁니다. 같은 장치는 여러 장면에서 공유돼요.")
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            Divider().padding(.top, 20)

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("장면 만들기") {
                    store.addScene(from: template, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? template.name : name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .churchProminentButton()
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 960)
        .onAppear { name = uniqueName(template.name) }
    }

    /// "설교"가 이미 있으면 "설교 2"
    private func uniqueName(_ base: String) -> String {
        let names = Set(store.scenes.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

private struct TemplateCard: View {
    let template: SceneTemplate
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TemplateThumbnail(template: template)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            Text(template.name).font(.uiHeadline)
            if template.summary.isEmpty {
                Text("소스 없이 직접 구성").font(.uiCaption).foregroundStyle(.secondary)
            } else {
                FlowChips(items: template.summary)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: ChurchShape.floating))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.floating)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.uiTitle3).padding(18)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ChurchShape.floating))
    }
}

/// 템플릿 슬롯을 색 블록으로
private struct TemplateThumbnail: View {
    let template: SceneTemplate

    private func kind(_ role: SceneTemplate.Role) -> SourceKind {
        switch role {
        case .mainCamera: .camera
        case .mainMic, .backgroundMusic: .audio
        case .browser(_, let url): url == nil ? .text : .browser
        case .window: .window
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if template.slots.isEmpty {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(template.slots.enumerated()), id: \.offset) { _, slot in
                    let k = kind(slot.role)
                    if k.isVisual {
                        let size = CGSize(width: slot.frame.width * geo.size.width,
                                          height: slot.frame.height * geo.size.height)
                        k.tint
                            .clipShape(slot.shape.shape(in: size))
                            .overlay { if slot.hasBorder { slot.shape.shape(in: size).stroke(.white.opacity(0.7)) } }
                            .frame(width: size.width, height: size.height)
                            .offset(x: slot.frame.minX * geo.size.width, y: slot.frame.minY * geo.size.height)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChurchShape.badge))
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        // 3개 이하라 단순 줄바꿈 레이아웃으로 충분
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(items, id: \.self) {
            Text($0).font(.uiCaption2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - 소스 추가

struct AddSourceSheet: View {
    @Bindable var store: ShowStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case new = "새로 만들기", reuse = "기존 소스 재사용" }

    @State private var mode: Mode = .new
    @State private var kind: SourceKind = .window
    @State private var name = ""
    @State private var nameEdited = false

    // 종류별 선택값
    @State private var mediaPath = ""
    @State private var textValue = ""
    @State private var pickedWindow: SCWindow?
    @State private var pickedDisplay: DisplayChoice?
    @State private var cropChrome = false
    @State private var captureAppAudio = false
    @State private var urlText = ""
    @State private var youtubeURL = ""
    @State private var youtubeLoop = true
    @State private var transparent = true
    @State private var deviceID: String?
    @State private var reuseSourceID: Source.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("소스 추가").font(.uiTitle3.weight(.bold))
                if let s = store.selectedScene {
                    Text("장면 「\(s.name)」에").font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            Divider()

            HStack(spacing: 0) {
                kindList.frame(width: 280)
                Divider()
                Group {
                    if mode == .reuse { reusePane } else { detailPane }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                if mode == .new {
                    Text("소스 이름").font(.uiCaption).foregroundStyle(.secondary)
                    TextField("소스 이름", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("추가", action: add)
                    .keyboardShortcut(.defaultAction)
                    .churchProminentButton()
                    .disabled(!canAdd)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 960, height: 640)
        .onChange(of: deviceID) {
            guard !nameEdited, let id = deviceID else { return }
            let list = kind == .camera ? store.cameraDevices : store.microphoneDevices
            if let n = store.deviceName(id, in: list) { name = n; nameEdited = false }
        }
        .onDisappear { store.probeAudio(nil) }
        .onChange(of: kind) { resetForKind() }
        .onAppear { resetForKind() }
    }

    // 왼쪽: 종류 (묶음별)
    private var kindGroups: [(String, [SourceKind])] {
        var groups: [(String, [SourceKind])] = [
            (L("카메라·소리"), [.camera, .audio]),
            (L("자료"), [.window, .screen, .media, .youtube]),
            (L("문구·그래픽"), [.text, .graphic]),
        ]
        // WORDaLIVE를 쓰지 않으면 그 소스는 보이지 않게 (이미 장면에 있는 것은 그대로 작동)
        switch WordaliveFeed.shared.mode {
        case .studio: groups.append(("WORDaLIVE", [.slides, .captions]))
        case .captions: groups.append(("WORDaLIVE", [.captions]))
        case .off: break
        }
        return groups
    }

    private var kindList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(kindGroups.enumerated()), id: \.offset) { _, group in
                    Text(group.0).font(.uiCaption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                    ForEach(group.1) { k in kindRow(k) }
                }
            }
            .padding(10)
        }
    }

    private func kindRow(_ k: SourceKind) -> some View {
        Button { kind = k } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: k.symbol)
                    .frame(width: 30, height: 30)
                    .background(k.tint, in: RoundedRectangle(cornerRadius: ChurchShape.button))
                    .foregroundStyle(k.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(k.title).font(.uiBody.weight(.semibold))
                    Text(k.subtitle).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(kind == k ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: ChurchShape.button))
            .overlay(RoundedRectangle(cornerRadius: ChurchShape.button).strokeBorder(kind == k ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 오른쪽: 새로 만들기
    @ViewBuilder private var detailPane: some View {
        switch kind {
        case .screen:
            VStack(alignment: .leading, spacing: 12) {
                DisplayPickerGrid(selection: $pickedDisplay)
                PresentationTips(screenMode: true)
            }
            .onChange(of: pickedDisplay) {
                if !nameEdited, let d = pickedDisplay { name = d.isMain ? L("주 화면") : d.name }
            }
        case .window:
            VStack(alignment: .leading, spacing: 12) {
                PresentationTips(screenMode: false)
                WindowPickerGrid(selection: $pickedWindow)
                Spacer()
                GroupBox {
                    Toggle("제목줄 자동 제거 · 준비 중", isOn: $cropChrome).disabled(true)
                    Toggle("이 앱의 소리도 함께 캡처", isOn: $captureAppAudio).disabled(!store.supportsAppAudio)
                }
            }
            .onChange(of: pickedWindow) {
                if !nameEdited, let w = pickedWindow {
                    name = PresentationApps.name(w.owningApplication?.bundleIdentifier).map { $0 + " " + L("슬라이드") } ?? w.owningApplication?.applicationName ?? w.title ?? L("윈도우")
                }
            }

        case .text:
            VStack(alignment: .leading) { Text("문구·가사").font(.uiHeadline); TextEditor(text: $textValue).frame(minHeight: 180) }
        case .youtube:
            VStack(alignment: .leading, spacing: 12) {
                Text("유튜브 영상 주소를 붙여 넣으세요.").font(.uiBody)
                TextField("유튜브 주소", text: $youtubeURL, prompt: Text("https://youtu.be/… 또는 https://www.youtube.com/watch?v=…"))
                    .textFieldStyle(.roundedBorder)
                if let id = YouTubeLink.videoID(youtubeURL), let thumb = YouTubeLink.thumbnail(id) {
                    AsyncImage(url: thumb) { image in image.resizable().aspectRatio(16 / 9, contentMode: .fit) } placeholder: { Color.black.aspectRatio(16 / 9, contentMode: .fit) }
                        .frame(maxHeight: 200).clipShape(RoundedRectangle(cornerRadius: 8))
                } else if !youtubeURL.isEmpty {
                    Text("유튜브 영상 주소가 아닙니다.").font(.uiCaption).foregroundStyle(.orange)
                }
                Toggle("끝나면 처음부터 반복", isOn: $youtubeLoop)
                Text("송출 장면에 들어가면 처음부터 재생되고, 다른 장면으로 바꾸면 멈춥니다. 소리는 기본으로 방송과 현장 모두에 나가며, 장면의 오디오에서 바꿀 수 있습니다. 인터넷 연결이 필요합니다.")
                    .font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .onChange(of: youtubeURL) { if !nameEdited { name = L("유튜브 영상") } }
        case .graphic:
            VStack(alignment: .leading, spacing: 8) {
                Text("아이콘을 누르면 장면에 바로 들어갑니다. 장면 편집 왼쪽 ‘그래픽’ 탭에서도 끌어 놓을 수 있어요.")
                    .font(.uiCaption).foregroundStyle(.secondary)
                GraphicsPanel(store: store)
            }
        case .media:
            VStack(alignment: .leading, spacing: 8) {
                Text("썸네일을 누르면 장면에 바로 들어갑니다. Finder에서 파일을 끌어 놓아도 됩니다.")
                    .font(.uiCaption).foregroundStyle(.secondary)
                MediaPanel(store: store)
            }
        case .slides:
            VStack(alignment: .leading, spacing: 12) {
                Text("WORDaLIVE 스튜디오에서 지금 송출 중인 슬라이드를 장면에 넣습니다.").font(.uiBody)
                CaptionsStatusRow()
                Text("준비 화면의 ‘WORDaLIVE 번역 자막’에서 연결하고, WORDaLIVE 스튜디오의 ‘OBS로 보내기’를 켜 두세요.")
                    .font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
            }
        case .captions:
            VStack(alignment: .leading, spacing: 12) {
                Text("WORDaLIVE 번역 화면의 자막을 방송 화면 아래쪽에 띄웁니다.").font(.uiBody)
                CaptionsStatusRow()
                Text("자막 연결은 준비 화면의 ‘WORDaLIVE 번역 자막’에서 합니다. 추가한 뒤 장면에서 위치·크기를 조정하고, 오른쪽 속성에서 원문 표시·글자 크기를 바꿀 수 있습니다.")
                    .font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
            }
        case .browser:
            Form {
                TextField("URL", text: $urlText, prompt: Text("https://… 또는 가사·자막 페이지 주소"))
                Toggle("투명 배경 (자막·오버레이용)", isOn: $transparent)
                Text("1920×1080으로 렌더링되며, 장면에서 위치·크기를 조정할 수 있습니다.")
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

        case .camera:
            Form {
                Picker("카메라", selection: $deviceID) {
                    Text("준비 화면의 보정 카메라" + (store.deviceName(store.mainCameraDeviceID, in: store.cameraDevices).map { " · \($0)" } ?? "")).tag(String?.none)
                    ForEach(store.isPro ? store.cameraDevices.filter { $0.id != store.mainCameraDeviceID } : []) { Text($0.name).tag(String?.some($0.id)) }
                }
                if !store.isPro {
                    Label("무료 요금제는 카메라 1대입니다. 여러 대의 카메라는 Pro에서 사용할 수 있습니다.", systemImage: "lock.fill")
                        .font(.uiCaption).foregroundStyle(.secondary)
                }
                Text(deviceID == nil ? L("얼굴 보정이 적용된 메인 카메라입니다. 여러 장면에서 함께 씁니다.")
                                     : L("두 번째 카메라로 엽니다. 얼굴 보정은 메인 카메라에만 적용됩니다."))
                    .font(.uiCaption).foregroundStyle(.secondary)
                if store.cameraDevices.count <= 1 {
                    Text("다른 카메라가 보이지 않으면 연결한 뒤 준비 화면의 ‘장치 새로고침’을 누르세요.")
                        .font(.uiCaption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

        case .audio:
            Form {
                Picker("오디오 입력", selection: $deviceID) {
                    Text("준비 화면의 마이크" + (store.deviceName(store.mainMicDeviceID, in: store.microphoneDevices).map { " · \($0)" } ?? "")).tag(String?.none)
                    ForEach(store.microphoneDevices.filter { $0.id != store.mainMicDeviceID }) { Text($0.name).tag(String?.some($0.id)) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("소리 확인").font(.uiCaption).foregroundStyle(.secondary)
                        Spacer()
                        Text(store.probeLevel > 0.02 ? L("들어오는 중") : L("소리가 없습니다")).font(.uiCaption2)
                            .foregroundStyle(LevelMeter.fraction(store.probeLevel) > 0.25 ? ChurchStatus.ok : Color.secondary)
                    }
                    LevelMeter(value: store.probeLevel, height: 12, showsDB: true)
                    Text("말하거나 음악을 틀어 막대가 움직이는지 확인하세요. 이 소리는 아직 방송에 나가지 않습니다.")
                        .font(.uiCaption2).foregroundStyle(.secondary)
                }
                Text("특정 앱의 소리만 받으려면 윈도우 캡처에서 ‘이 앱의 소리도 함께 캡처’를 켜세요.")
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .onAppear { store.probeAudio(deviceID ?? store.mainMicDeviceID) }
            .onChange(of: deviceID) { store.probeAudio(deviceID ?? store.mainMicDeviceID) }
            .onDisappear { store.probeAudio(nil) }
        }
    }

    // 오른쪽: 기존 소스 재사용
    @ViewBuilder private var reusePane: some View {
        let inScene = Set(store.selectedScene?.items.map(\.sourceID) ?? [])
        let candidates = store.sources.filter { $0.kind == kind && !inScene.contains($0.id) }
        if candidates.isEmpty {
            Text("이 장면에 추가할 수 있는 기존 \(kind.title) 소스가 없습니다.")
                .foregroundStyle(.secondary)
        } else {
            List(candidates, selection: $reuseSourceID) { s in
                Label(s.name, systemImage: s.kind.symbol).tag(s.id)
            }
        }
    }

    private var canAdd: Bool {
        guard store.selectedScene != nil else { return false }
        if mode == .reuse { return reuseSourceID != nil }
        switch kind {
        case .window: return pickedWindow != nil
        case .screen: return pickedDisplay != nil
        case .browser: return store.supportsBrowser && URL(string: urlText)?.scheme != nil
        case .youtube: return YouTubeLink.videoID(youtubeURL) != nil
        case .text: return !textValue.isEmpty
        case .media: return false   // 미디어는 썸네일을 눌러 바로 추가
        case .graphic: return false   // 그래픽은 아래 목록에서 바로 추가
        case .camera, .audio, .captions, .slides: return true
        }
    }

    private func resetForKind() {
        nameEdited = false
        reuseSourceID = nil
        deviceID = nil
        pickedWindow = nil
        name = switch kind {
        case .window: L("윈도우")
        case .screen: L("프로젝터 화면")
        case .browser: L("브라우저")
        case .camera: L("카메라")
        case .audio: L("마이크")
        case .text: L("문구·가사")
        case .media: L("사진·영상")
        case .youtube: L("유튜브 영상")
        case .graphic: L("그래픽")
        case .captions: L("WORDaLIVE 자막")
        case .slides: L("WORDaLIVE 슬라이드")
        }
        nameEdited = false
    }

    private func add() {
        if mode == .reuse, let id = reuseSourceID {
            store.addExistingSource(id)
        } else {
            let config: SourceConfig = switch kind {
            case .text:
                .text(value: textValue, opaque: false)
            case .media:
                .media(path: mediaPath, loop: true, audioOnly: ["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff"].contains(URL(fileURLWithPath: mediaPath).pathExtension.lowercased()))
            case .graphic:
                .graphic(icon: "", color: "FFFFFF", path: "")
            case .screen:
                .screen(displayID: pickedDisplay?.id, name: pickedDisplay?.name)
            case .window:
                .window(bundleID: pickedWindow?.owningApplication?.bundleIdentifier,
                        windowTitle: pickedWindow?.title,
                        cropChrome: cropChrome, captureAppAudio: captureAppAudio)
            case .browser:
                .browser(url: URL(string: urlText), transparentBackground: transparent, width: 1920, height: 1080)
            case .camera:
                .camera(deviceID: deviceID)
            case .audio:
                .audio(deviceID: deviceID, appBundleID: nil)
            case .captions:
                .captions(showSource: false, background: true, fontSize: 56, lines: 1)
            case .slides:
                .slides
            case .youtube:
                .youtube(url: youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines), loop: youtubeLoop)
            }
            store.addNewSource(kind: kind, name: name, config: config)
            if kind == .window, let window = pickedWindow, let id = store.selectedItem?.sourceID {
                store.runtimeWindowIDs[id] = window.windowID
                store.refreshPreview()
            }
        }
        dismiss()
    }
}

// MARK: - 열린 창 목록 (ScreenCaptureKit)

struct WindowPickerGrid: View {
    @Binding var selection: SCWindow?
    @State private var windows: [SCWindow] = []
    @State private var thumbs: [CGWindowID: CGImage] = [:]
    @State private var error: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("캡처할 창 선택").font(.uiHeadline)
                Spacer()
                Button("새로고침") { Task { await load() } }.buttonStyle(.link)
            }
            if error != nil {
                ScreenPermissionNotice(compact: true)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(windows, id: \.windowID) { w in
                        let picked = selection?.windowID == w.windowID
                        Button { selection = w } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    Color.secondary.opacity(0.15)
                                    if let img = thumbs[w.windowID] {
                                        Image(decorative: img, scale: 1).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                                    }
                                }
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: ChurchShape.badge))
                                HStack(spacing: 6) {
                                    Text(w.owningApplication?.applicationName ?? L("앱")).font(.uiCallout.weight(.semibold))
                                    if PresentationApps.isPresentation(w.owningApplication?.bundleIdentifier) {
                                        Text("슬라이드").font(.uiCaption2.weight(.bold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: ChurchShape.badge))
                                    }
                                }
                                Text((w.title?.isEmpty == false ? w.title : nil) ?? L("슬라이드 쇼 창")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(10)
                            .background(picked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: ChurchShape.button))
                            .overlay(RoundedRectangle(cornerRadius: ChurchShape.button)
                                .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownBundle = Bundle.main.bundleIdentifier
            let list = content.windows.filter {
                $0.isOnScreen && $0.frame.width > 200 && $0.frame.height > 150
                && ($0.title?.isEmpty == false || PresentationApps.isPresentation($0.owningApplication?.bundleIdentifier))
                && $0.owningApplication?.bundleIdentifier != ownBundle
            }
            // PowerPoint·Keynote·ProPresenter 창을 맨 앞에, 그 안에서는 큰 창(슬라이드 쇼) 먼저
            .sorted { a, b in
                let pa = PresentationApps.isPresentation(a.owningApplication?.bundleIdentifier)
                let pb = PresentationApps.isPresentation(b.owningApplication?.bundleIdentifier)
                if pa != pb { return pa }
                return a.frame.width * a.frame.height > b.frame.width * b.frame.height
            }
            await MainActor.run { windows = list; error = nil }
            for w in list.prefix(12) {
                if let img = try? await thumbnail(w) {
                    await MainActor.run { thumbs[w.windowID] = img }
                }
            }
        } catch {
            await MainActor.run {
                self.error = "permission"
            }
        }
    }

    private func thumbnail(_ w: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        cfg.width = 480
        cfg.height = Int(480 * w.frame.height / max(w.frame.width, 1))
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}


// MARK: - 프로젝터 화면 고르기

struct DisplayPickerGrid: View {
    @Binding var selection: DisplayChoice?
    @State private var displays: [DisplayChoice] = []
    @State private var thumbs: [String: CGImage] = [:]
    @State private var error: String?
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("가져올 모니터 선택").font(.uiHeadline)
                Spacer()
                Button("새로고침") { Task { await load() } }.buttonStyle(.link)
            }
            if error != nil { ScreenPermissionNotice(compact: true) }
            if displays.count == 1 {
                Label("모니터가 하나뿐입니다. 프로젝터나 두 번째 모니터를 연결하면 그 화면을 고를 수 있습니다. 모니터가 하나라면 ‘윈도우 캡처’로 슬라이드 쇼 창을 가져오세요.", systemImage: "info.circle")
                    .font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(displays) { d in
                    let picked = selection?.id == d.id
                    Button { selection = d } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                Color.secondary.opacity(0.15)
                                if let img = thumbs[d.id] { Image(decorative: img, scale: 1).resizable().scaledToFit() }
                                else { Image(systemName: "display").foregroundStyle(.secondary) }
                            }
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: ChurchShape.badge))
                            HStack(spacing: 6) {
                                Text(d.name).font(.uiCallout.weight(.semibold)).lineLimit(1)
                                if d.isMain { Text("주 화면").font(.uiCaption2).foregroundStyle(.secondary) }
                                else { Text("추천").font(.uiCaption2.weight(.bold)).foregroundStyle(ChurchStatus.ok) }
                            }
                            Text("\(Int(d.size.width)) × \(Int(d.size.height))").font(.uiCaption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(picked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button))
                        .overlay(RoundedRectangle(cornerRadius: ChurchShape.button).strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let list = await MainActor.run { DisplayChoice.current().sorted { !$0.isMain && $1.isMain } }
        await MainActor.run {
            displays = list
            if selection == nil { selection = list.first { !$0.isMain } }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run { error = nil }
            for d in list {
                guard let display = content.displays.first(where: { $0.displayID == d.displayID }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = 480; cfg.height = Int(480 * d.size.height / max(d.size.width, 1)); cfg.showsCursor = false
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                    await MainActor.run { thumbs[d.id] = img }
                }
            }
        } catch {
            await MainActor.run { self.error = "permission" }
        }
    }
}

/// PowerPoint·Keynote·ProPresenter 를 방송에 넣는 두 가지 방법 안내
struct PresentationTips: View {
    let screenMode: Bool
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                tip("PowerPoint", screenMode
                    ? L("슬라이드 쇼를 프로젝터(두 번째 모니터)에 띄우고, 노트북에는 발표자 보기를 두세요. 여기서 그 모니터를 고르면 됩니다.")
                    : L("슬라이드 쇼 › 슬라이드 쇼 설정 › ‘웹 형식으로 보기(창)’(Browsed by an individual)을 고르고 쇼를 시작하면 창으로 뜹니다. 그 창을 고르세요."))
                tip("Keynote", screenMode
                    ? L("설정 › 슬라이드쇼에서 프로젝터 모니터를 발표 화면으로 정하세요.")
                    : L("재생 › ‘윈도우에서 슬라이드쇼 재생’(Play Slideshow in Window)으로 시작하면 창으로 뜹니다."))
                tip("ProPresenter", screenMode
                    ? L("화면 설정(Screens)에서 청중(Audience) 화면을 프로젝터 모니터로 보내고 그 모니터를 고르세요.")
                    : L("청중(Audience) 화면을 창으로 띄울 수 있으면 그 창을, 아니면 ‘화면 캡처’로 청중 화면이 나가는 모니터를 고르세요."))
                Text(screenMode ? L("모니터가 하나뿐이라면 ‘윈도우 캡처’로 슬라이드 쇼 창을 가져오세요.")
                                : L("파일을 바꿔도 같은 앱의 슬라이드 창을 자동으로 다시 찾습니다."))
                    .font(.uiCaption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Label(screenMode ? L("프로젝터 화면을 가져오는 법") : L("PowerPoint·Keynote·ProPresenter를 창으로 띄우는 법"), systemImage: "lightbulb")
                .font(.uiCallout.weight(.semibold))
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button))
    }
    private func tip(_ app: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(app).font(.uiCaption.weight(.bold)).frame(width: 92, alignment: .leading)
            Text(text).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
