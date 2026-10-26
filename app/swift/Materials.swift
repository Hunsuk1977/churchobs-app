// SPDX-License-Identifier: GPL-2.0-or-later
// 자료 단계: 방송·프로젝터에 띄울 내용을 어디서 가져올지 고른다.
//   · WORDaLIVE    — 찬양·성경·설교 슬라이드와 실시간 번역 자막. 스튜디오 화면을 헤더만 빼고 꽉 채워 쓴다.
//   · 창 가져오기  — PowerPoint·Keynote·ProPresenter 등 다른 프로그램의 창(장면의 창·화면 캡처 소스).
//   · 직접 만들기  — PDF·사진 몇 장을 넘기는 아주 단순한 넘김기. 인터넷 없이도 된다.
// 자막 레이어는 여기와 무관하게 WORDaLIVE 연결 설정이 정한다.
import SwiftUI
import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

enum MaterialsSource: String, CaseIterable, Identifiable {
    case wordalive, window, builtin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wordalive: "WORDaLIVE"
        case .window: L("창 가져오기")
        case .builtin: L("직접 만들기")
        }
    }
    var symbol: String {
        switch self {
        case .wordalive: "globe"
        case .window: "macwindow.on.rectangle"
        case .builtin: "doc.on.doc"
        }
    }
    var detail: String {
        switch self {
        case .wordalive: L("찬양·성경·설교 슬라이드와 실시간 번역 자막. 사용 시간은 WORDaLIVE 계정에서 계산됩니다.")
        case .window: L("PowerPoint·Keynote·ProPresenter 등 지금 쓰는 프로그램의 창을 그대로 가져옵니다.")
        case .builtin: L("PDF·사진·짧은 문구를 넘깁니다. 인터넷이 없어도 됩니다.")
        }
    }
}

/// 자료 단계의 상태. 고른 소스는 이 Mac에 기억되고(다음 주에도 그대로), 시나리오에도 함께 저장된다.
@MainActor @Observable
final class MaterialsStore {
    static let shared = MaterialsStore()

    var source: MaterialsSource? = MaterialsSource(rawValue: UserDefaults.standard.string(forKey: "materials.source") ?? "") {
        didSet {
            UserDefaults.standard.set(source?.rawValue ?? "", forKey: "materials.source")
            if source == .builtin { show() } else if oldValue == .builtin { WordaliveFeed.shared.resendSlide() }
        }
    }

    // ── 직접 만들기 ──
    /// 슬라이드 PNG 파일 (PDF는 장마다 한 장으로 풀어 둔다)
    private(set) var pages: [URL] = []
    private(set) var labels: [String] = []
    private(set) var index = 0
    var blank = false { didSet { show() } }
    private(set) var importing = ""
    /// 엔진으로 슬라이드를 보내는 통로 (path 빈 값 = 없음)
    @ObservationIgnored var sink: ((String, Bool) -> Void)?

    private static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChurchOBS/materials", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() { restorePages() }

    func go(_ i: Int) {
        guard pages.indices.contains(i) else { return }
        index = i
        show()
    }
    func next() { go(index + 1) }
    func previous() { go(index - 1) }

    private func show() {
        guard source == .builtin else { return }
        let path = pages.indices.contains(index) ? pages[index].path : ""
        sink?(path, blank)
    }

    /// PDF·이미지 파일을 자료로 넣는다. PDF는 1920px 너비 PNG로 장마다 풀어 둔다.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = L("불러오는 중…")
        Task.detached(priority: .userInitiated) { [urls] in
            var made: [(URL, String)] = []
            for file in urls {
                let ext = file.pathExtension.lowercased()
                if ext == "pdf", let doc = PDFDocument(url: file) {
                    for i in 0..<doc.pageCount {
                        guard let page = doc.page(at: i) else { continue }
                        let bounds = page.bounds(for: .mediaBox)
                        let scale = 1920 / max(bounds.width, 1)
                        let size = NSSize(width: 1920, height: (bounds.height * scale).rounded())
                        let image = NSImage(size: size)
                        image.lockFocus()
                        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
                        if let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.saveGState(); ctx.scaleBy(x: scale, y: scale); page.draw(with: .mediaBox, to: ctx); ctx.restoreGState()
                        }
                        image.unlockFocus()
                        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else { continue }
                        let out = MaterialsStore.folder.appendingPathComponent("\(UUID().uuidString).png")
                        if (try? png.write(to: out)) != nil { made.append((out, "\(file.deletingPathExtension().lastPathComponent) \(i + 1)")) }
                    }
                } else if NSImage(contentsOf: file) != nil {
                    let out = MaterialsStore.folder.appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "img" : ext)")
                    if (try? FileManager.default.copyItem(at: file, to: out)) != nil { made.append((out, file.deletingPathExtension().lastPathComponent)) }
                }
            }
            let result = made
            await MainActor.run {
                self.pages.append(contentsOf: result.map { $0.0 })
                self.labels.append(contentsOf: result.map { $0.1 })
                self.importing = ""
                self.savePages()
                if self.pages.count == result.count { self.go(0) }
            }
        }
    }

    func remove(_ i: Int) {
        guard pages.indices.contains(i) else { return }
        try? FileManager.default.removeItem(at: pages[i])
        pages.remove(at: i); labels.remove(at: i)
        if index >= pages.count { index = max(0, pages.count - 1) }
        savePages(); show()
    }
    func clear() {
        for p in pages { try? FileManager.default.removeItem(at: p) }
        pages = []; labels = []; index = 0
        savePages(); show()
    }
    func move(from: Int, to: Int) {
        guard pages.indices.contains(from), (0...pages.count).contains(to), from != to else { return }
        let p = pages.remove(at: from); let l = labels.remove(at: from)
        let at = to > from ? to - 1 : to
        pages.insert(p, at: at); labels.insert(l, at: at)
        savePages()
    }

    private struct Saved: Codable { var files: [String]; var labels: [String] }
    private func savePages() {
        let saved = Saved(files: pages.map(\.lastPathComponent), labels: labels)
        try? JSONEncoder().encode(saved).write(to: Self.folder.appendingPathComponent("pages.json"))
    }
    private func restorePages() {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent("pages.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let fm = FileManager.default
        var files: [URL] = []; var names: [String] = []
        for (i, name) in saved.files.enumerated() {
            let url = Self.folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            files.append(url); names.append(i < saved.labels.count ? saved.labels[i] : name)
        }
        pages = files; labels = names
    }
}

// MARK: - 화면

struct MaterialsView: View {
    let session: StudioSession
    @State private var store = MaterialsStore.shared

    var body: some View {
        Group {
            if let source = store.source {
                VStack(spacing: 0) {
                    strip(source)
                    Divider()
                    switch source {
                    case .wordalive:
                        WordaliveStudioPane(fullscreen: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    case .window:
                        WindowMaterialsView(session: session)
                    case .builtin:
                        BuiltinMaterialsView(store: store)
                    }
                }
            } else {
                MaterialsPicker { store.source = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 단계 머리줄: 고른 소스 칩(눌러서 바꾸기)
    private func strip(_ source: MaterialsSource) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(MaterialsSource.allCases) { s in
                    Button { store.source = s } label: {
                        Label(s.title, systemImage: s == source ? "checkmark" : s.symbol)
                    }
                }
                Divider()
                Button(L("다시 고르기")) { store.source = nil }
            } label: {
                Label(source.title, systemImage: source.symbol).font(.uiHeadline)
            }
            .menuStyle(.button).fixedSize()
            .help(L("자료를 어디서 가져올지 바꿉니다"))
            Text(source.detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

/// 처음 들어왔을 때: 카드 세 장
private struct MaterialsPicker: View {
    let pick: (MaterialsSource) -> Void
    @State private var host = WordaliveStudioHost.shared

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 6) {
                Text("자료를 어디서 가져올까요?").font(.system(size: 24, weight: .bold))
                Text("방송과 프로젝터에 띄울 슬라이드·자막의 출처입니다. 나중에 위쪽 칩에서 바꿀 수 있습니다.")
                    .font(.uiBody).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(MaterialsSource.allCases) { s in
                    Button { pick(s) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: s.symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(ChurchBrand.blue)
                            Text(s.title).font(.system(size: 19, weight: .bold))
                            Text(s.detail).font(.uiCaption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if s == .wordalive {
                                Text(host.needsLink ? L("계정 연결이 필요합니다") : (host.email.isEmpty ? L("연결됨") : host.email))
                                    .font(.uiCaption2).foregroundStyle(host.needsLink ? .orange : ChurchStatus.ok).lineLimit(1)
                            } else if s == .window {
                                Text(ScreenPermission.shared.granted ? L("화면 기록 허용됨") : L("화면 기록 권한이 필요합니다"))
                                    .font(.uiCaption2).foregroundStyle(ScreenPermission.shared.granted ? ChurchStatus.ok : .orange)
                            } else {
                                Text(L("인터넷 없이 사용")).font(.uiCaption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                        .frame(width: 280, height: 230, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .churchGlass(ChurchShape.panel, interactive: true)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 창 가져오기: 장면의 창·화면 캡처 소스를 크게 본다
private struct WindowMaterialsView: View {
    let session: StudioSession
    @State private var permission = ScreenPermission.shared

    private var hasCapture: Bool { session.store.sources.contains { $0.kind == .window || $0.kind == .screen } }

    var body: some View {
        VStack(spacing: 14) {
            if !permission.granted {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("다른 프로그램의 창을 가져오려면 macOS ‘화면 기록’ 권한이 필요합니다.").font(.uiBody)
                    Spacer()
                    Button("권한 요청") { permission.request() }.churchProminentButton()
                }
                .padding(14).churchGlass(ChurchShape.panel)
            }
            if hasCapture {
                MaterialMonitorPanel(store: session.store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("이 창은 장면에 넣은 창·화면 캡처 소스입니다. 어느 장면에 어떻게 놓일지는 ‘장면’ 단계에서 정합니다. 프로그램(PowerPoint 등)에서 슬라이드를 넘기면 그대로 따라갑니다.")
                    .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 640)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "macwindow.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("아직 가져온 창이 없습니다").font(.uiTitle3)
                    Text("‘장면’ 단계에서 장면에 ‘창 캡처’ 소스를 추가하고 PowerPoint·Keynote·ProPresenter 창을 고르세요. 그러면 여기와 송출 화면에 그 창이 보입니다.")
                        .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                    Button(L("장면 단계로")) { session.requestPhase(StudioSession.scenes) }.churchProminentButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
    }
}

/// 직접 만들기: PDF·사진 넘김기 — 이 이상은 넣지 않는다 (제대로 된 찬양·성경 덱은 WORDaLIVE)
private struct BuiltinMaterialsView: View {
    @Bindable var store: MaterialsStore
    @State private var dropping = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // 왼쪽: 목록
            VStack(spacing: 8) {
                HStack {
                    Text(L("슬라이드") + " \(store.pages.count)").font(.uiHeadline)
                    Spacer()
                    Button { pickFiles() } label: { Label("추가", systemImage: "plus") }
                    if !store.pages.isEmpty {
                        Menu {
                            Button("모두 지우기", role: .destructive) { store.clear() }
                        } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).fixedSize()
                    }
                }
                .buttonStyle(.borderless)
                if store.pages.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("PDF·사진을 여기에 끌어다 놓거나 ‘추가’를 누르세요").font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("PowerPoint는 PDF로 내보내서 넣으세요").font(.uiCaption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(store.pages.enumerated()), id: \.element) { i, url in
                                Button { store.go(i) } label: {
                                    HStack(spacing: 10) {
                                        Text("\(i + 1)").font(.uiCaption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                        AsyncThumb(url: url).frame(width: 96, height: 54)
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        Text(i < store.labels.count ? store.labels[i] : url.lastPathComponent)
                                            .font(.uiCaption).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(6)
                                    .background(i == store.index ? Color.red.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous).strokeBorder(i == store.index ? Color.red : Color.clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("지우기", role: .destructive) { store.remove(i) } }
                            }
                        }
                    }
                }
                if !store.importing.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.importing).font(.uiCaption).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 320)
            .padding(14)
            .churchGlass(ChurchShape.panel)
            .overlay(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous).strokeBorder(dropping ? ChurchBrand.blue : Color.clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in store.importFiles([url]) }
                    }
                }
                return true
            }

            // 오른쪽: 지금 슬라이드 크게 + 넘기기
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if store.blank {
                        Text("검정 화면").font(.uiCaption).foregroundStyle(.secondary)
                    } else if store.pages.indices.contains(store.index) {
                        AsyncThumb(url: store.pages[store.index], large: true)
                    } else {
                        Text("슬라이드를 추가하면 여기에 보입니다").font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
                .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    Button { store.previous() } label: { Label("이전", systemImage: "chevron.left") }
                        .churchButton().disabled(store.index == 0 || store.pages.isEmpty)
                    Button { store.next() } label: { Label("다음", systemImage: "chevron.right") }
                        .churchButton().disabled(store.index >= store.pages.count - 1)
                    Text(store.pages.isEmpty ? "" : "\(store.index + 1) / \(store.pages.count)").font(.uiBody.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(isOn: $store.blank) { Label("검정 화면", systemImage: "rectangle.fill") }
                        .toggleStyle(.button).tint(.red)
                    Text("← → 키로 넘깁니다").font(.uiCaption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .focusable()
            .onKeyPress(.rightArrow) { store.next(); return .handled }
            .onKeyPress(.leftArrow) { store.previous(); return .handled }
            .onKeyPress(.space) { store.next(); return .handled }
        }
        .padding(18)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .heic, .tiff, .gif, .bmp]
        panel.message = L("PDF·사진을 고르세요 (PowerPoint는 PDF로 내보내기)")
        panel.begin { if $0 == .OK { store.importFiles(panel.urls) } }
    }
}

/// 파일 그림을 화면 크기에 맞춰 가볍게 보여 준다
private struct AsyncThumb: View {
    let url: URL
    /// 큰 미리보기(지금 슬라이드) — 지금은 표시 크기만 다르다
    var large = false
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.secondary.opacity(0.15) }
        }
        .task(id: url) {
            // 그림은 크지 않다(1920px PNG) → 그대로 읽어 화면에서 줄인다
            image = NSImage(contentsOf: url)
        }
    }
}
