// SPDX-License-Identifier: GPL-2.0-or-later
// 자료 모니터: PowerPoint·Keynote·ProPresenter 창이나 프로젝터 화면을 Church OBS 안에서 바로 본다.
// 엔진과 상관없이 ScreenCaptureKit으로 따로 받으므로, 그 소스가 지금 장면에 없어도 보인다.
import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage

@MainActor @Observable
final class SourceMonitor: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var image: CGImage?
    private(set) var status = ""
    private(set) var running = false
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private let context = CIContext(options: [.cacheIntermediates: false])
    @ObservationIgnored private var lastFrame: TimeInterval = 0
    @ObservationIgnored private var sourceID: UUID?
    /// 소스 설정이 바뀌었을 때 다시 잡게 한다
    func refresh(_ source: Source) { sourceID = nil; show(source) }

    /// 소스 설정(윈도우·화면)으로 캡처 대상을 찾아 시작한다
    func show(_ source: Source) {
        if sourceID == source.id, running { return }
        sourceID = source.id
        Task { await start(source) }
    }

    func stop() {
        let s = stream; stream = nil
        running = false; image = nil; sourceID = nil
        Task { try? await s?.stopCapture() }
    }

    private func start(_ source: Source) async {
        let old = stream; stream = nil; running = false
        try? await old?.stopCapture()
        status = L("찾는 중…")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            var size = CGSize(width: 1280, height: 720)
            switch source.config {
            case let .window(bundle, title, _, _):
                let candidates = content.windows.filter { w in
                    guard w.isOnScreen, w.frame.width > 200, w.frame.height > 150 else { return false }
                    if let bundle, !bundle.isEmpty, w.owningApplication?.bundleIdentifier != bundle { return false }
                    return true
                }
                // 제목이 맞는 창 → 같은 앱의 가장 큰 창(슬라이드 쇼)
                let picked = candidates.first { $0.title == title && !(title ?? "").isEmpty }
                    ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let window = picked else { status = L("창을 찾지 못했습니다. 슬라이드 쇼를 켜 두세요."); return }
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            case let .screen(displayID, _):
                let displays = DisplayChoice.current()
                let choice = displays.first { $0.id == displayID } ?? displays.first { !$0.isMain } ?? displays.first
                guard let choice, let display = content.displays.first(where: { $0.displayID == choice.displayID }) else { status = L("모니터를 찾지 못했습니다."); return }
                filter = SCContentFilter(display: display, excludingWindows: [])
                size = choice.size
            default:
                status = L("윈도우·화면 소스만 볼 수 있습니다."); return
            }
            let cfg = SCStreamConfiguration()
            let scale = min(1, 960 / max(size.width, 1))
            cfg.width = Int(size.width * scale); cfg.height = Int(size.height * scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)   // 10fps면 충분하고 가볍다
            cfg.showsCursor = false
            cfg.queueDepth = 3
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "church.monitor"))
            try await s.startCapture()
            stream = s; running = true; status = ""
        } catch {
            status = L("화면 녹화 권한이 필요합니다.") + " · " + error.localizedDescription
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.image = cg
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.running = false; self.status = L("창이 닫혔습니다.") ; self.image = nil
        }
    }
}

/// 진행 화면의 자료 모니터 패널
struct MaterialMonitorPanel: View {
    @Bindable var store: ShowStore
    @State private var monitor = SourceMonitor()
    @AppStorage("ui.materialMonitorSource") private var chosen = ""

    private var candidates: [Source] { store.sources.filter { $0.kind == .window || $0.kind == .screen } }
    private var current: Source? { candidates.first { $0.id.uuidString == chosen } ?? candidates.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.inset.filled.and.person.filled").foregroundStyle(.secondary)
                Text("자료 모니터").font(.uiCaption.weight(.semibold))
                Spacer()
                if candidates.count > 1 {
                    Picker("자료", selection: Binding(get: { current?.id.uuidString ?? "" }, set: { chosen = $0 })) {
                        ForEach(candidates) { Text($0.name).tag($0.id.uuidString) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
            }
            ZStack {
                Color.black
                if let img = monitor.image {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: current == nil ? "macwindow" : "hourglass").foregroundStyle(.secondary)
                        Text(current == nil ? L("윈도우·화면 캡처 소스를 장면에 넣으면 여기에 보입니다") : (monitor.status.isEmpty ? L("연결 중…") : monitor.status))
                            .font(.uiCaption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 8)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
        }
        .onAppear { if let s = current { monitor.show(s) } }
        .onChange(of: current?.id) { if let s = current { monitor.show(s) } else { monitor.stop() } }
        .onChange(of: current?.config) { if let s = current { monitor.refresh(s) } }
        .onDisappear { monitor.stop() }
    }
}

/// 출력 창 메뉴: 송출 화면을 프로젝터·두 번째 모니터에 전체 화면으로, 또는 별도 창으로
struct ProjectorMenu: View {
    let session: StudioSession
    private var open: Bool { session.flag("projector") }
    private var store: ShowStore { session.store }
    private var fixedName: String? { store.scenes.first { $0.id == store.projectorSceneID }?.name }

    var body: some View {
        Menu {
            Button("별도 창으로 열기 (이 화면에서 확인)") { session.command("projector", ["windowed": true]) }
            Section(L("프로젝터·다른 모니터에 전체 화면")) {
                let others = DisplayChoice.current().filter { !$0.isMain }
                if others.isEmpty {
                    Text("연결된 프로젝터·모니터가 없습니다")
                } else {
                    ForEach(others) { d in
                        Button(d.name + " · \(Int(d.size.width))×\(Int(d.size.height))") { session.command("projector", ["display": d.id, "windowed": false]) }
                    }
                }
            }
            Section(L("출력 창에 띄울 것")) {
                Button { session.store.setProjectorScene(nil) } label: {
                    Label("송출 화면 그대로", systemImage: store.projectorSceneID == nil ? "checkmark" : "rectangle.on.rectangle")
                }
                ForEach(store.scenes) { scene in
                    Button { session.store.setProjectorScene(scene.id) } label: {
                        Label(scene.name, systemImage: store.projectorSceneID == scene.id ? "checkmark" : "rectangle")
                    }
                }
            }
            if open { Divider(); Button("출력 창 닫기", role: .destructive) { session.store.setProjectorScene(nil); session.command("projector") } }
        } label: {
            Label(open ? L("출력 창") + " · " + (fixedName ?? L("송출과 같게")) : L("출력 창"), systemImage: open ? "tv.fill" : "tv")
                .lineLimit(1)
        }
        .menuStyle(.button).fixedSize()
        .tint(open ? ChurchBrand.blue : nil)
        .help("출력 창: 현장 프로젝터·다른 모니터에 전체 화면으로, 또는 이 화면에 별도 창으로 띄웁니다. 송출 화면 그대로 또는 고른 장면을 보낼 수 있습니다. 전체 화면은 Esc 대신 이 메뉴에서 닫습니다.")
    }
}
