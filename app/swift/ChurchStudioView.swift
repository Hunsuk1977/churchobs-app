// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AVFoundation
import AppKit

@MainActor
struct ChurchStudioView: View {
    @State var session: StudioSession
    let preview: NSView
    @State private var showLogin = false
    @State private var showScenarios = false
    @State private var screen = ScreenPermission.shared
    @State private var wordalive = WordaliveFeed.shared
    @AppStorage("gate.developerContinue") private var developerContinue = false
    @AppStorage("ui.cameraPanelOpen") private var cameraPanelOpen = true
    @AppStorage("ui.wordaliveStudio") private var showWordaliveStudio = true
    /// WORDaLIVE 스튜디오를 쓸 때 오른쪽 송출 기둥을 펼쳐 둘지 (기본: 접어서 스튜디오가 거의 전체 화면)
    @AppStorage("ui.broadcastDrawer") private var broadcastDrawerOpen = false
    @AppStorage("ui.materialMonitor") private var showMaterialMonitor = false
    @State private var beautyCompare = false
    @State private var showBeautyDetail = false

    /// 첫 화면: 로그인해야 들어간다 (서버 연결 전 개발 모드에서만 건너뛰기 가능)
    private var needsLogin: Bool {
        // 방송·녹화 중에는 로그인이 풀려도 화면을 가리지 않는다
        !session.account.signedIn && !(AccountService.developmentMode && developerContinue) && !session.locked
    }

    var body: some View {
        if needsLogin {
            WelcomeGate(account: session.account) { developerContinue = true }
                .frame(minWidth: 1240, minHeight: 780)
                .font(.uiBody)
                .controlSize(.large)
                .churchChrome()
                .preferredColorScheme(.dark)
        } else {
            studio
                .task {
                    // 받은 자막을 엔진의 자막 띠로 보낸다. 지난번에 켜 두었으면 다시 연결
                    let owner = session
                    wordalive.sink = { [weak owner] lines in
                        _ = owner?.bridge?.studioCommand("captions", arguments: ["lines": lines])
                    }
                    wordalive.styleSink = { [weak owner] style in
                        _ = owner?.bridge?.studioCommand("captionStyle", arguments: style)
                    }
                    wordalive.slideSink = { [weak owner] path, blank in
                        _ = owner?.bridge?.studioCommand("slide", arguments: ["path": path, "blank": blank])
                    }
                    wordalive.layoutSink = { [weak owner] layout in owner?.store.followWordaliveLayout(layout) }
                    if wordalive.mode == .captions, wordalive.autoStart, !wordalive.isOn, !wordalive.link.isEmpty { wordalive.start() }
                }
        }
    }

    private var wordaliveReady: Bool {
        switch wordalive.mode {
        case .off: false
        case .captions: wordalive.status == .connected
        case .studio: !WordaliveStudioHost.shared.needsLink
        }
    }
    private var wordaliveDetail: String {
        switch wordalive.mode {
        case .off: L("설교 실시간 번역 자막·슬라이드를 방송에 가져옵니다")
        case .captions: wordalive.isOn ? wordalive.statusText : L("번역 자막만 방송에 띄웁니다")
        case .studio: WordaliveStudioHost.shared.needsLink ? L("WORDaLIVE 계정을 연결하세요") : L("슬라이드·번역 자막·배치를 WORDaLIVE 스튜디오에서 받습니다")
        }
    }
    /// 진행 화면 왼쪽 스튜디오는 ‘슬라이드까지’일 때만
    private var studioVisible: Bool { wordalive.mode == .studio && showWordaliveStudio }

    private var studio: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if session.phase == 0 { preparation }
                else if session.phase == 1 {
                    SceneEditorView(store: session.store, extraInspector: AnyView(cameraPanel(wide: false)), compositePreview: AnyView(EngineSurface(preview: preview)), sourcePreview: { _ in AnyView(Color.clear) }, audioLevel: session.audioLevel)
                        .disabled(session.locked)
                } else { performance }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Claude 앱 기준: 본문 15pt, 버튼 한 단계 크게
        .font(.uiBody)
        .controlSize(.large)
        .churchChrome()
        .frame(minWidth: 1240, minHeight: 780)
        .background(Color(red: 0.055, green: 0.065, blue: 0.08))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $session.showReview) { reviewSheet }
        .sheet(isPresented: $showLogin) { LoginSheet(account: session.account) }
        .alert("가상 카메라 준비가 필요합니다", isPresented: $session.showVirtualCameraHelp) {
            Button("OBS Studio 받기") { NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!) }
            Button("확인", role: .cancel) {}
        } message: {
            Text("Church OBS는 macOS에 설치된 ‘OBS Virtual Camera’ 장치를 씁니다.\n\n1. OBS Studio(무료)를 설치합니다.\n2. OBS를 열고 ‘가상 카메라 시작’을 한 번 눌러 시스템 설정에서 허용합니다.\n3. OBS를 닫고 Church OBS에서 ‘가상 카메라’를 누릅니다.\n\nZoom·Meet에서는 카메라를 ‘OBS Virtual Camera’로 고르세요.")
        }
        .sheet(isPresented: $showScenarios) {
            ScenarioLibrarySheet(account: session.account, currentTitle: session.store.title,
                                 editable: !session.locked && session.phase != 2,
                                 onSave: { name, overwrite in await session.saveScenario(name: name, overwrite: overwrite) },
                                 onOpen: { id in await session.openScenario(id) },
                                 onLogin: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showLogin = true } })
        }
    }
    private var header: some View {
        HStack(spacing: 20) {
            ChurchLogo(height: 36)
                .frame(width: 230, alignment: .leading)
            Spacer()
            PhaseStepper(phase: session.phase,
                         ready: session.flag("ready"),
                         sceneCount: session.store.scenes.count,
                         live: session.flag("live"),
                         recording: session.flag("recording"),
                         locked: session.locked,
                         select: session.requestPhase)
            Spacer()
            // 준비 화면은 카드가 같은 정보를 크게 보여 준다 → 헤더 칩은 장면·진행 화면에서만
            if session.phase != 0 || session.flag("live") {
            HStack(spacing: 12) {
                statusDot("카메라", session.flag("camera"))
                statusDot("마이크", session.flag("microphone"))
                statusDot("YouTube", session.flag("youtube"))
                if session.flag("virtualCam") { statusDot("가상 카메라", true) }
                if session.flag("live") { Label("LIVE", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red).font(.uiCaption.bold()) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .churchGlass(ChurchShape.floating)
            }
            AccountMenu(account: session.account, onLogin: { showLogin = true }, onScenarios: { showScenarios = true })
        }.padding(.horizontal, 22).padding(.vertical, 14)
    }
    /// 연결되면 초록 체크, 아니면 빈 원
    private func statusDot(_ text: String, _ ready: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ready ? AnyShapeStyle(ChurchStatus.ok) : AnyShapeStyle(Color.secondary.opacity(0.6)))
            Text(L(text)).font(.uiCaption.weight(ready ? .semibold : .regular))
                .foregroundStyle(ready ? Color.primary : Color.secondary)
        }
        .help(ready ? "\(text) 연결됨" : "\(text) 연결 안 됨")
    }
    // MARK: 1 준비

    private var cameraName: String? { devices("cameras").first { $0.id == (session.state["cameraID"] as? String ?? "") }?.name }
    private var microphoneName: String? { devices("microphones").first { $0.id == (session.state["microphoneID"] as? String ?? "") }?.name }
    /// 연결 전: 진행 중 메시지나 오류가 있으면 그대로 보여 주고, 없으면 안내 문구
    private var youtubeIdleDetail: String {
        let status = (session.state["youtubeStatus"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return status.isEmpty || status == L("계정을 연결하세요") ? L("선택 · 라이브 방송할 때만 연결하세요") : status
    }
    /// YouTube가 "이 채널은 라이브가 꺼져 있음"이라고 답했는지 (채널 주인이 YouTube에서 직접 켜야 함)
    private var youtubeLiveBlocked: Bool {
        let text = [session.state["youtubeStatus"] as? String, session.state["error"] as? String, session.errorText]
            .compactMap { $0 }.joined(separator: " ")
        return text.contains("liveStreamingNotEnabled") || text.contains("livePermissionBlocked")
    }
    private var micMeter: Float { (session.state["micLevel"] as? NSNumber)?.floatValue ?? microphoneLevel }

    private var preparation: some View {
        let required = [session.flag("camera"), session.flag("microphone")]
        let done = required.filter { $0 }.count
        return HStack(alignment: .top, spacing: 24) {
            // 왼쪽: 점검 목록
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("방송 전 점검").font(.uiTitle2.bold())
                        Text(done == required.count ? "필수 항목이 모두 준비되었습니다" : "필수 \(done)/\(required.count) · 카메라와 마이크를 연결하세요")
                            .font(.uiCaption).foregroundStyle(done == required.count ? ChurchStatus.ok : .secondary)
                    }
                    Spacer()
                    Button { session.command("refresh") } label: { Image(systemName: "arrow.clockwise") }
                        .help("장치 목록 새로고침").accessibilityLabel("장치 새로고침")
                    Menu {
                        Button("설정 불러오기…") { session.loadCopy() }
                        Button("설정 내보내기…") { session.saveCopy() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                    .help("설정 파일 불러오기·내보내기")
                }

                ScrollView {
                    VStack(spacing: 12) {
                        CheckCard(status: session.flag("camera") ? .ok : .required, number: 1, title: L("카메라"),
                                  detail: session.flag("camera") ? "연결됨 · \(cameraName ?? "카메라")" : "사용할 카메라를 고른 뒤 연결하세요") {
                            Button(session.flag("camera") ? L("다시 연결") : L("연결")) { session.command("camera", ["id": session.cameraChoice]) }
                                .churchStyle(prominent: !session.flag("camera"))
                        } content: {
                            Picker("카메라", selection: $session.cameraChoice) { ForEach(devices("cameras"), id: \.id) { Text($0.name).tag($0.id) } }
                                .labelsHidden()
                        }
                        CheckCard(status: session.flag("microphone") ? .ok : .required, number: 2, title: L("마이크"),
                                  detail: session.flag("microphone") ? "연결됨 · \(microphoneName ?? "마이크")" : "강단 마이크나 오디오 인터페이스를 연결하세요") {
                            Button(session.flag("microphone") ? L("다시 연결") : L("연결")) { session.command("microphone", ["id": session.microphoneChoice]) }
                                .churchStyle(prominent: !session.flag("microphone"))
                        } content: {
                            Picker("마이크", selection: $session.microphoneChoice) { ForEach(devices("microphones"), id: \.id) { Text($0.name).tag($0.id) } }
                                .labelsHidden()
                            if session.flag("microphone") {
                                HStack(spacing: 8) {
                                    Image(systemName: session.flag("muted") ? "mic.slash.fill" : "mic.fill")
                                        .foregroundStyle(session.flag("muted") ? Color.red : .secondary)
                                    LevelMeter(value: micMeter, showsDB: true)
                                }
                                Text("말해 보면 막대가 움직여야 합니다. 테스트 녹화로 소리까지 확인하세요.").font(.uiCaption2).foregroundStyle(.secondary)
                            }
                        }
                        CheckCard(status: screen.granted ? .ok : .optional, number: 3, title: L("화면 녹화 권한"),
                                  detail: screen.granted ? L("허용됨 · 자료 창(PPT·가사)을 캡처할 수 있습니다") : L("자료 창을 캡처할 때 필요합니다")) {
                            if !screen.granted && !screen.requested {
                                Button("권한 요청") { screen.request() }.churchStyle(prominent: false)
                            }
                        } content: {
                            if !screen.granted && screen.requested {
                                Text("시스템 설정에서 Church OBS를 켠 뒤 다시 시작하세요.").font(.uiCaption).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button("시스템 설정 열기") { screen.openSettings() }
                                    Button("다시 시작") { screen.relaunch() }.disabled(session.locked)
                                }
                            }
                        }
                        CheckCard(status: session.flag("youtube") ? .ok : .optional, number: 4, title: L("YouTube 방송"),
                                  detail: session.flag("youtube") ? (session.state["youtubeStatus"] as? String ?? L("연결됨")) : youtubeIdleDetail) {
                            if session.flag("youtube") {
                                // 연결된 뒤에는 계정 바꾸기·해제만 필요하다
                                Menu {
                                    Button("다른 계정으로 바꾸기…") { session.command("youtubeSwitch") }
                                    Button("이 Mac에서 연결 해제", role: .destructive) { session.command("youtubeDisconnect") }
                                } label: { Text("계정") }
                                .menuStyle(.button).fixedSize()
                            } else {
                                Button(L("연결")) { session.command("youtube") }
                                    .churchStyle(prominent: false)
                            }
                        } content: {
                            QualityPicker(locked: session.locked)
                            if session.flag("youtube") {
                                BroadcastSetup(live: !(session.state["activeBroadcast"] as? String ?? "").isEmpty) { privacy in
                                    session.command("broadcastPrivacy", ["privacy": privacy])
                                }
                                InternetCheckRow()
                            }
                            // 채널의 라이브가 꺼져 있으면 목록조차 못 받아 '연결 안 됨'으로 남는다 → 연결 여부와 상관없이 안내
                            if youtubeLiveBlocked { YouTubeLiveSetupNotice() }
                        }
                        CheckCard(status: wordaliveReady ? .ok : .optional, number: 5, title: L("WORDaLIVE"),
                                  detail: wordaliveDetail) {
                            if wordalive.mode == .captions {
                                Button(wordalive.isOn ? L("끊기") : L("연결")) { wordalive.isOn ? wordalive.stop() : wordalive.start() }
                                    .churchStyle(prominent: false)
                            }
                        } content: {
                            WordaliveSetup(store: session.store)
                        }
                    }
                    .disabled(session.locked)
                    .padding(.bottom, 4)
                }

                Button { session.requestPhase(1) } label: {
                    HStack { Text("장면 편집으로"); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity)
                }
                .churchProminentButton()
                .controlSize(.extraLarge)
                .disabled(!session.flag("ready") || session.locked)
            }
            .frame(width: 440)

            // 오른쪽: 미리보기 + 화면 보정.
            // 스크롤 영역을 두면 내용 높이가 화면과 비슷할 때 스크롤 막대가 생겼다 사라지며 깜빡인다 →
            // 보정 패널은 아래에 고정하고, 미리보기가 남는 공간에 맞춰 줄어든다
            VStack(alignment: .leading, spacing: 16) {
                    EngineSurface(preview: preview)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Label("미리보기 · 아직 방송되지 않습니다", systemImage: "eye")
                                .font(.uiCaption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .churchGlass(ChurchShape.button)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(-1)
                    cameraPanel(wide: true)
                        .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .onAppear { screen.refresh() }
    }

    /// 얼굴 보정 + 색 톤 + 배경 흐림을 한 패널로. 머리줄을 누르면 접히고, 접혀 있을 때는 현재 설정을 한 줄로 보여 준다
    private func cameraPanel(wide: Bool) -> some View {
        let pro = session.account.features.beauty
        let preset = session.state["beautyPreset"] as? Int ?? 0
        let tone = session.state["lookTone"] as? Int ?? 0
        let blur = (session.state["lookBlur"] as? NSNumber)?.doubleValue ?? 0
        let hasCamera = session.flag("camera")
        let presetNames = [L("끔"), L("자연스럽게"), L("조금 더")]
        let toneNames = [L("원본"), L("따뜻하게"), L("맑게"), L("차분하게"), L("필름")]
        let summary = [preset > 0 ? L("보정") + " " + presetNames[min(preset, 2)] : nil,
                       tone > 0 ? toneNames[min(tone, 4)] : nil,
                       blur > 0 ? L("배경 흐림") + " \(Int(blur))" : nil].compactMap { $0 }
        let controlsOff = !hasCamera || session.locked || session.phase == 2 || !pro
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { cameraPanelOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera.filters").foregroundStyle(.secondary)
                    Text("카메라 보정").font(.uiHeadline)
                    if !pro {
                        Label("Pro", systemImage: "lock.fill").font(.uiCaption2.weight(.bold)).foregroundStyle(.secondary)
                            .help("보정·색 톤·배경 흐림은 Pro 요금제에서 사용할 수 있습니다")
                    }
                    Spacer(minLength: 8)
                    if !cameraPanelOpen {
                        Text(summary.isEmpty ? L("꺼짐") : summary.joined(separator: " · "))
                            .font(.uiCaption).foregroundStyle(summary.isEmpty ? Color.secondary : ChurchStatus.ok).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(cameraPanelOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 13)

            if cameraPanelOpen {
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 12) {
                    if !hasCamera {
                        Label("카메라를 연결하면 사용할 수 있습니다", systemImage: "info.circle").font(.uiCaption).foregroundStyle(.secondary)
                    }
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                beautyControls(preset: preset, wide: true).frame(maxWidth: .infinity, alignment: .topLeading)
                                Divider()
                                lookControls(tone: tone, blur: blur, wide: true).frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            beautyControls(preset: preset, wide: false)
                            lookControls(tone: tone, blur: blur, wide: false)
                        }
                    }
                    .disabled(controlsOff)
                    Divider()
                    Button {
                        AVCaptureDevice.showSystemUserInterface(.videoEffects)
                    } label: { Label("macOS 인물 사진 효과", systemImage: "person.crop.rectangle").font(.uiCaption) }
                    .buttonStyle(.link)
                    .help("FaceTime과 같은 macOS 카메라 효과(인물 사진·스튜디오 조명)를 켜고 끕니다. 카메라 자체에 적용됩니다.")
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .churchGlass(ChurchShape.panel)
        .clipShape(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous))
    }

    /// 넓은 곳: 이름표 왼쪽 · 좁은 곳(장면 편집 속성): 이름표 위 — 컨트롤이 패널 밖으로 넘치지 않게
    private func panelRow<Control: View>(_ title: String, wide: Bool = true, @ViewBuilder _ control: () -> Control) -> some View {
        Group {
            if wide {
                HStack(spacing: 12) {
                    Text(L(title)).font(.uiCaption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    control().frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(title)).font(.uiCaption).foregroundStyle(.secondary)
                    control().frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func beautyControls(preset: Int, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            panelRow("얼굴 보정", wide: wide) {
                Picker("얼굴 보정", selection: Binding(get: { preset }, set: { session.command("beauty", ["preset": $0]) })) {
                    Text("끔").tag(0); Text("자연스럽게").tag(1); Text("조금 더").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
            }
            // 세부 조정은 떠 있는 창으로: 펼쳐도 패널 높이가 바뀌지 않아 화면이 튀지 않는다
            panelRow("세부", wide: wide) {
                HStack(spacing: 8) {
                    Button { showBeautyDetail.toggle() } label: {
                        Label("피부·얼굴형·눈매·눈썹", systemImage: "slider.horizontal.3").font(.uiCaption)
                    }
                    .disabled(preset == 0)
                    .popover(isPresented: $showBeautyDetail, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("세부 조정").font(.uiHeadline)
                            ForEach(["strength", "skin", "shape", "eyes", "brows"], id: \.self) { key in
                                let title = ["strength": "전체 강도", "skin": "피부", "shape": "얼굴형", "eyes": "눈매", "brows": "눈썹"][key] ?? key
                                panelRow(title) {
                                    Slider(value: Binding(get: { (session.state[key] as? NSNumber)?.doubleValue ?? 0 }, set: { session.command("beauty", [key: $0]) }), in: 0...100)
                                }
                            }
                            Toggle("원본과 나란히 비교", isOn: Binding(get: { beautyCompare }, set: { beautyCompare = $0; session.command("beauty", ["compare": $0]) }))
                                .toggleStyle(.switch).controlSize(.small)
                        }
                        .padding(16).frame(width: 340)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func lookControls(tone: Int, blur: Double, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            panelRow("색 톤", wide: wide) {
                let picker = Picker("색 톤", selection: Binding(get: { tone }, set: { session.command("look", ["tone": $0]) })) {
                    Text("원본").tag(0); Text("따뜻하게").tag(1); Text("맑게").tag(2); Text("차분하게").tag(3); Text("필름").tag(4)
                }.labelsHidden()
                // 다섯 칸 버튼은 좁은 속성 패널에 들어가지 않는다 → 좁을 때는 펼침 메뉴
                if wide { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading) }
            }
            // 원본일 때도 자리는 지켜 둔다 (색 톤을 고를 때마다 패널 높이가 바뀌어 화면이 튀던 문제)
            panelRow("톤 강도", wide: wide) {
                Slider(value: Binding(get: { (session.state["lookToneAmount"] as? NSNumber)?.doubleValue ?? 60 },
                                      set: { session.command("look", ["amount": $0]) }), in: 0...100)
            }
            .disabled(tone == 0)
            .opacity(tone == 0 ? 0.4 : 1)
            panelRow("배경 흐림", wide: wide) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { blur }, set: { session.command("look", ["blur": $0]) }), in: 0...100)
                    Text(blur > 0 ? "\(Int(blur))" : L("끔")).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                }
            }
            Text("사람 뒤쪽만 흐리게 합니다. 추가 카메라는 장면 편집의 카메라 속성에서 따로 정할 수 있습니다.")
                .font(.uiCaption2).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)   // 창 너비가 바뀌어도 높이는 그대로
        }
    }
    /// 진행 화면: 왼쪽에 WORDaLIVE 스튜디오(슬라이드·번역), 오른쪽에 좁은 송출 기둥(송출·전환·미리보기·장면)
    private var performance: some View {
        Group {
            performanceBody
        }
        .overlay(alignment: .top) {
            if broadcastStep > 0 {
                BroadcastProgressBanner(step: broadcastStep, status: session.state["youtubeStatus"] as? String ?? "")
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: broadcastStep)
    }

    private var performanceBody: some View {
        Group {
            if studioVisible {
                // 스튜디오가 상단(헤더)만 빼고 거의 전체를 차지한다. 송출 기둥은 오른쪽 서랍 —
                // 접으면 얇은 레일(송출 전환·LIVE·마이크)만 남고, 펼치면 380pt 기둥이 된다.
                HStack(alignment: .top, spacing: broadcastDrawerOpen ? 12 : 0) {
                    WordaliveStudioPane {
                        withAnimation(.snappy(duration: 0.25)) { showWordaliveStudio = false }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if broadcastDrawerOpen {
                        VStack(spacing: 0) {
                            HStack {
                                Text("송출").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button { withAnimation(.snappy(duration: 0.25)) { broadcastDrawerOpen = false } } label: { Image(systemName: "chevron.right") }
                                    .buttonStyle(.borderless).help(L("송출 패널 접기"))
                            }
                            .padding(.bottom, 6)
                            compactPerformance
                        }
                        .frame(width: 380)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        broadcastRail
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.leading, 10).padding(.trailing, broadcastDrawerOpen ? 14 : 0).padding(.vertical, 8)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // 숨긴 스튜디오는 왼쪽 가장자리의 얇은 탭으로 다시 연다
                    if wordalive.mode == .studio { studioRail }
                    fullPerformance.padding(.horizontal, 24).padding(.vertical, 16)
                }
            }
        }
    }

    /// 송출 기둥을 접었을 때 오른쪽 가장자리의 얇은 레일: 펼치기·송출 전환·LIVE·마이크
    private var broadcastRail: some View {
        VStack(spacing: 14) {
            Button { withAnimation(.snappy(duration: 0.25)) { broadcastDrawerOpen = true } } label: {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.uiCaption2.weight(.bold)).foregroundStyle(.secondary)
                    Image(systemName: "sidebar.right").font(.system(size: 15, weight: .semibold))
                    Text("송출")
                        .font(.uiCaption.weight(.semibold))
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 40)
                }
                .frame(width: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("송출 패널 펼치기 — 미리보기·전환·장면"))
            Divider().frame(width: 28)
            // 송출 전환 (미리보기 → 송출)
            Button { session.store.take() } label: {
                Image(systemName: "arrow.right.to.line").font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .churchButton()
            .disabled(session.store.previewSceneID == nil)
            .help(L("송출 전환 (미리보기 장면을 방송으로)"))
            if session.flag("live") {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red).font(.uiCaption.bold()).help("LIVE")
            } else if session.flag("recording") {
                Image(systemName: "record.circle").foregroundStyle(.red).font(.uiCaption.bold()).help(L("녹화 중"))
            }
            Spacer()
            // 마이크 레벨 (세로)
            LevelMeter(value: microphoneLevel, segments: 12, showsDB: false)
                .frame(width: 80, height: 10)
                .rotationEffect(.degrees(-90))
                .frame(width: 10, height: 80)
            Image(systemName: session.flag("muted") ? "mic.slash.fill" : "mic.fill")
                .font(.uiCaption).foregroundStyle(session.flag("muted") ? .red : .secondary)
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1) }
    }

    /// 스튜디오를 숨겼을 때 왼쪽 가장자리 탭
    private var studioRail: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { showWordaliveStudio = true }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left").font(.system(size: 15, weight: .semibold))
                Text("WORDaLIVE")
                    .font(.uiCaption.weight(.semibold))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 96)
                Image(systemName: "chevron.right").font(.uiCaption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(width: 40)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1) }
        .help(L("WORDaLIVE 스튜디오 보이기"))
    }

    private var monitors: StudioMonitors {
        StudioMonitors(preview: preview, program: session.programView,
                       previewName: sceneName(session.store.previewSceneID),
                       programName: sceneName(session.store.programSceneID),
                       live: session.flag("live"), recording: session.flag("recording"),
                       connecting: !(session.state["activeBroadcast"] as? String ?? "").isEmpty && !session.flag("live"),
                       canTake: session.store.previewSceneID != nil,
                       vertical: studioVisible) { session.store.take() }
    }

    /// 자료 모니터 켜고 끄기 (PowerPoint 창·프로젝터 화면을 방송 중에도 바로 본다)
    private var materialToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showMaterialMonitor.toggle() }
        } label: { Label("자료 모니터", systemImage: showMaterialMonitor ? "macwindow.badge.plus" : "macwindow") }
        .churchButton()
        .tint(showMaterialMonitor ? ChurchStatus.ok : nil)
        .help("윈도우·화면 캡처 소스(PowerPoint 등)를 장면과 상관없이 여기서 바로 봅니다")
    }

    @ViewBuilder private var countdownControls: some View {
        if session.store.programSceneID == session.store.scenes.first?.id {
            Text(session.countdownLabel).monospacedDigit().font(.uiHeadline)
            Button(session.countdownRunning ? L("카운트다운 일시 정지") : L("카운트다운 시작")) { session.toggleCountdown() }
            Button("초기화") { session.resetCountdown() }
        }
    }

    private var compactPerformance: some View {
        VStack(alignment: .leading, spacing: 12) {
            monitors
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.uiCaption).foregroundStyle(.secondary)
                LevelMeter(value: microphoneLevel, segments: 20, showsDB: true)
            }
            HStack(spacing: 8) {
                countdownControls
                Spacer(minLength: 0)
                materialToggle
                ProjectorMenu(session: session)
            }
            .controlSize(.small)
            if showMaterialMonitor { MaterialMonitorPanel(store: session.store) }
            LiveMediaSoundBar(store: session.store)
            Divider()
            LiveSceneDeck(store: session.store, compact: true) { session.requestPhase(1) }
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var fullPerformance: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                monitors.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showMaterialMonitor {
                    MaterialMonitorPanel(store: session.store).frame(width: 300)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                countdownControls
                Spacer()
                materialToggle
                ProjectorMenu(session: session)
                Text("마이크").font(.uiCaption).foregroundStyle(.secondary)
                LevelMeter(value: microphoneLevel, segments: 24, showsDB: true).frame(width: 190)
            }
            LiveMediaSoundBar(store: session.store)
            LiveSceneDeck(store: session.store) { session.requestPhase(1) }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !session.errorText.isEmpty { Text(session.errorText).font(.uiCaption).foregroundStyle(.orange).lineLimit(2) }
            HStack(spacing: 12) {
                Button { session.command("mute") } label: {
                    Label(session.flag("muted") ? L("마이크 꺼짐") : L("마이크 켜짐"), systemImage: session.flag("muted") ? "mic.slash.fill" : "mic.fill")
                }
                .tint(session.flag("muted") ? .red : nil)
                .disabled(!session.flag("microphone"))
                Button { session.command("record") } label: {
                    Label(session.flag("stopping") ? L("파일 저장 중…") : session.flag("recording") ? L("녹화 종료") : L("테스트 녹화"),
                          systemImage: session.flag("recording") ? "stop.circle.fill" : "record.circle")
                }
                .tint(session.flag("recording") ? .red : nil)
                .disabled(!session.flag("camera") || session.flag("stopping"))
                if !(session.state["recordingPath"] as? String ?? "").isEmpty && !session.flag("recording") { Button("녹화 파일 보기") { session.command("recordingFile") } }
                if !(session.state["activeBroadcast"] as? String ?? "").isEmpty { Button("방송 상태 확인") { session.command("broadcastStatus") } }
                Spacer()
                if session.phase != 0 {
                    Text(session.state["youtubeStatus"] as? String ?? "").font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                if session.flag("youtube") || StreamHealth(session.state["stream"] as? [String: Any]).active {
                    NetworkPill(stream: StreamHealth(session.state["stream"] as? [String: Any]))
                }
                Button { session.toggleVirtualCamera() } label: {
                    Label(session.flag("virtualCam") ? L("가상 카메라 끄기") : L("가상 카메라"),
                          systemImage: session.flag("virtualCam") ? "video.fill" : "video.badge.plus")
                }
                .tint(session.flag("virtualCam") ? ChurchStatus.ok : nil)
                .disabled(!session.flag("ready"))
                .help("송출 화면을 Zoom·Google Meet 등에서 카메라로 쓸 수 있게 합니다")
                if session.phase == 2 {
                    if broadcastStep > 0 {
                        // 시작·종료에는 몇 초가 걸린다 → 누른 것이 받아들여졌다는 것을 바로 보여 준다
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(broadcastStep == 5 ? L("방송 마치는 중…") : L("방송 시작하는 중…")).font(.uiBody.weight(.semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background((broadcastStep == 5 ? Color.red : ChurchBrand.blue).opacity(0.18), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
                    } else {
                        Button((session.state["activeBroadcast"] as? String ?? "").isEmpty ? L("방송 시작") : L("방송 종료")) { session.command("broadcast") }
                            .churchProminentButton(session.flag("live") ? .red : ChurchBrand.blue).disabled(session.flag("busy"))
                    }
                }
            }.controlSize(.large)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("진행 전 마지막 확인").font(.uiTitle2.bold())
            Text("장면 편집에서 각 화면을 확인하고 테스트 녹화로 소리를 확인하세요. 진행 화면에서는 장치와 레이어 편집이 잠깁니다.")
            Text("진행 화면으로 이동해도 YouTube 방송은 자동 시작되지 않습니다.").font(.uiCaption).foregroundStyle(.secondary)
            HStack { Stepper("카운트다운 \(session.countdownMinutes)분", value: $session.countdownMinutes, in: 1...180); Toggle("0초에 다음 장면", isOn: $session.countdownAuto) }
            Toggle("화면과 소리를 확인했습니다", isOn: $session.reviewed)
            HStack { Spacer(); Button("취소") { session.showReview = false }; Button("진행 화면으로") { session.showReview = false; session.enterPerformance() }.churchProminentButton().disabled(!session.reviewed) }
        }.padding(28).frame(width: 600)
    }
    private func devices(_ key: String) -> [StudioDeviceChoice] {
        (session.state[key] as? [[String: String]] ?? []).compactMap { value in guard let id = value["id"], let name = value["name"] else { return nil }; return StudioDeviceChoice(id: id, name: name) }
    }
    private var broadcastStep: Int { (session.state["broadcastStep"] as? NSNumber)?.intValue ?? 0 }
    private func sceneName(_ id: UUID?) -> String? { session.store.scenes.first { $0.id == id }?.name }
    private var microphoneLevel: Float { guard let id = session.store.mainMicSourceID else { return 0 }; return session.audioLevel(id) }
}


/// 상단 단계 표시: 1 준비 → 2 장면 → 3 진행. 지금 어디에 있는지, 다음에 무엇을 할지 한눈에 보이게
struct PhaseStepper: View {
    let phase: Int
    let ready: Bool
    let sceneCount: Int
    let live: Bool
    let recording: Bool
    let locked: Bool
    let select: (Int) -> Void

    private struct Step { let number: Int; let title: String; let detail: String; let symbol: String; let done: Bool }

    private var steps: [Step] {
        [Step(number: 1, title: L("준비"), detail: ready ? L("점검 완료") : L("카메라·마이크 점검"), symbol: "checklist", done: ready && phase > 0),
         Step(number: 2, title: "장면", detail: sceneCount > 0 ? "장면 \(sceneCount)개" : "장면 만들기", symbol: "rectangle.3.group", done: phase > 1),
         Step(number: 3, title: L("진행"), detail: live ? L("방송 중") : recording ? L("녹화 중") : L("방송·녹화"), symbol: "dot.radiowaves.left.and.right", done: false)]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.number) { step in
                let index = step.number - 1
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(index <= phase ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.5))
                }
                stepButton(step, index: index)
            }
        }
        .padding(5)
        .churchGlass(ChurchShape.panel + 2)
    }

    private func tint(_ index: Int) -> Color { index == 2 && (live || recording) ? .red : .accentColor }

    @ViewBuilder
    private func stepButton(_ step: Step, index: Int) -> some View {
        let active = index == phase
        Button { select(index) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(active ? Color.white.opacity(0.95) : step.done ? tint(index).opacity(0.25) : Color.secondary.opacity(0.18))
                        .frame(width: 30, height: 30)
                    if step.done && !active {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(tint(index))
                    } else {
                        Text("\(step.number)").font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? tint(index) : Color.primary.opacity(0.8))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(step.title)).font(.system(size: 17, weight: .bold))
                    Text(L(step.detail)).font(.system(size: 11.5, weight: .medium))
                        .opacity(active ? 0.9 : 0.6)
                        .lineLimit(1)
                }
                if index == 2 && (live || recording) {
                    Circle().fill(active ? Color.white : Color.red).frame(width: 8, height: 8)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
            .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 6)
            .frame(minWidth: 150, alignment: .leading)
            .background(active ? tint(index) : Color.clear, in: RoundedRectangle(cornerRadius: ChurchShape.panel - 2, style: .continuous))
            .shadow(color: active ? tint(index).opacity(0.45) : .clear, radius: 8, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: ChurchShape.panel - 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(locked && !active)
        .help(index == 2 ? "방송 전 확인을 거쳐 진행 화면으로 갑니다" : "\(step.title) 화면으로")
        .accessibilityLabel("\(step.number)단계 \(step.title)\(active ? ", 현재 화면" : "")")
    }
}


/// 상태 색 (연결됨 = 초록)
enum ChurchStatus {
    static let ok = Color(red: 0.19, green: 0.78, blue: 0.40)
}

/// 준비 화면의 점검 카드: 왼쪽 상태 표시 + 제목·설명 + 오른쪽 동작 하나 + 아래 선택 칸
struct CheckCard<Trailing: View, Content: View>: View {
    enum Status { case ok, required, optional }
    let status: Status
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L(title)).font(.uiHeadline)
                            if status == .optional { Text("선택").font(.uiCaption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous)) }
                        }
                        Text(L(detail)).font(.uiCaption)
                            .foregroundStyle(status == .ok ? ChurchStatus.ok : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .churchGlass(ChurchShape.panel)
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous)
            .strokeBorder(status == .ok ? ChurchStatus.ok.opacity(0.35) : Color.clear, lineWidth: 1))
    }

    private var badge: some View {
        ZStack {
            switch status {
            case .ok:
                Circle().fill(ChurchStatus.ok)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
            case .required:
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
            case .optional:
                Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(status == .ok ? "\(title) 준비됨" : "\(title) 준비 안 됨")
    }
}

extension View {
    @ViewBuilder func churchStyle(prominent: Bool) -> some View {
        if prominent { churchProminentButton() } else { churchButton() }
    }
}


/// 채널의 라이브 방송이 아직 꺼져 있을 때: 교회(채널 주인)가 YouTube에서 직접 켜야 하는 일을 안내
struct YouTubeLiveSetupNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("이 채널은 아직 라이브 방송이 켜져 있지 않습니다", systemImage: "exclamationmark.triangle.fill")
                .font(.uiCallout.weight(.semibold)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. 아래 버튼으로 YouTube Studio를 엽니다.")
                Text("2. 만들기 › 라이브 스트리밍 시작 › 휴대폰 인증을 마칩니다.")
                Text("3. 처음 켜면 실제 방송까지 최대 24시간 걸릴 수 있습니다. 그 뒤 이 화면에서 다시 연결하세요.")
            }
            .font(.uiCaption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("YouTube에서 라이브 켜기") {
                    if let url = URL(string: "https://www.youtube.com/live_dashboard") { NSWorkspace.shared.open(url) }
                }
                .churchProminentButton()
                Button("도움말") {
                    if let url = URL(string: "https://support.google.com/youtube/answer/2474026?hl=ko") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}


/// 방송·녹화 화질 선택 (720p / 1080p). 바꾸면 앱을 다시 시작해야 적용된다
struct QualityPicker: View {
    let locked: Bool
    @State private var choice = VideoQuality.chosen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("방송 화질").font(.uiCaption).foregroundStyle(.secondary)
                Picker("방송 화질", selection: Binding(get: { choice }, set: { choice = $0; VideoQuality.chosen = $0 })) {
                    Text("720p · 기본").tag(VideoQuality.hd)
                    Text("1080p · 고화질").tag(VideoQuality.fullHD)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(locked)
            }
            Text(choice == .fullHD ? L("업로드 10Mbps 이상이 안정적입니다. 맥의 하드웨어 인코더로 내보냅니다.")
                                   : L("업로드 5.5Mbps 이상이면 충분합니다. 인터넷이 약한 곳에 알맞습니다."))
                .font(.uiCaption2).foregroundStyle(.secondary)
            if choice != VideoQuality.running {
                HStack(spacing: 8) {
                    Label("앱을 다시 시작하면 \(choice.title)로 바뀝니다", systemImage: "arrow.clockwise.circle")
                        .font(.uiCaption).foregroundStyle(.orange)
                    Button("지금 다시 시작") { ScreenPermission.shared.relaunch() }
                        .disabled(locked)
                }
            }
        }
    }
}


/// YouTube 방송 설정: 매번 새 방송을 만들므로 제목과 공개 범위만 정한다
struct BroadcastSetup: View {
    let live: Bool
    let onPrivacy: (String) -> Void
    @AppStorage("WSBroadcastPrivacy") private var privacy = "unlisted"
    @State private var title = ""

    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    private static var defaultTitle: String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        return f.string(from: Date()) + " " + L("예배")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("방송 제목").font(.uiCaption).foregroundStyle(.secondary)
                TextField("방송 제목", text: $title, prompt: Text(Self.defaultTitle))
                    .textFieldStyle(.roundedBorder)
                    .disabled(live)
                    .onChange(of: title) {
                        // 제목은 오늘 하루만 기억한다 (다음 주에는 새 날짜로)
                        UserDefaults.standard.set(title, forKey: "WSBroadcastTitle")
                        UserDefaults.standard.set(Self.today, forKey: "WSBroadcastTitleDate")
                    }
            }
            HStack(spacing: 10) {
                Text("공개 범위").font(.uiCaption).foregroundStyle(.secondary)
                Picker("공개 범위", selection: Binding(get: { privacy }, set: { privacy = $0; onPrivacy($0) })) {
                    Text("일부 공개").tag("unlisted")
                    Text("비공개").tag("private")
                    Text("공개").tag("public")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Text(privacy == "public" ? L("누구나 볼 수 있고 구독자에게 알림이 갈 수 있습니다.")
                 : privacy == "unlisted" ? L("링크를 받은 사람만 볼 수 있습니다. 시험 방송에 알맞습니다.")
                 : L("나와 초대한 사람만 볼 수 있습니다."))
                .font(.uiCaption2).foregroundStyle(.secondary)
            Text("‘방송 시작’을 누를 때마다 YouTube에 새 방송을 만들어 바로 시작합니다.")
                .font(.uiCaption2).foregroundStyle(.secondary)
        }
        .onAppear {
            if UserDefaults.standard.string(forKey: "WSBroadcastTitleDate") == Self.today {
                title = UserDefaults.standard.string(forKey: "WSBroadcastTitle") ?? ""
            }
        }
    }
}

/// 방송 시작·종료 중 단계 표시
struct BroadcastProgressBanner: View {
    let step: Int
    let status: String

    var body: some View {
        HStack(spacing: 18) {
            ProgressView().controlSize(.regular)
            if step == 5 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("방송을 마치는 중…").font(.uiHeadline)
                    Text("YouTube에 종료를 알리고 있습니다. 잠시 기다려 주세요.").font(.uiCaption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YouTube 방송을 시작하는 중…").font(.uiHeadline)
                    HStack(spacing: 14) {
                        stepLabel(1, L("방송 만들기"))
                        Image(systemName: "chevron.right").font(.uiCaption2).foregroundStyle(.tertiary)
                        stepLabel(2, L("영상 보내기"))
                        Image(systemName: "chevron.right").font(.uiCaption2).foregroundStyle(.tertiary)
                        stepLabel(3, L("YouTube 수신 확인"))
                    }
                    Text(step == 3 ? L("YouTube가 영상을 받는 데 보통 10~30초 걸립니다. 이 화면은 이미 송출되고 있습니다.") : status)
                        .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .churchGlass(ChurchShape.panel)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private func stepLabel(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: step > n ? "checkmark.circle.fill" : step == n ? "circle.dotted" : "circle")
                .foregroundStyle(step > n ? ChurchStatus.ok : step == n ? Color.accentColor : Color.secondary)
            Text(title).font(.uiCaption.weight(step == n ? .bold : .regular))
                .foregroundStyle(step >= n ? Color.primary : Color.secondary)
        }
    }
}
