// SPDX-License-Identifier: GPL-2.0-or-later
// 유튜브 영상 소스: 앱 안 보이지 않는 곳(다른 창 뒤)에 플레이어 창을 하나씩 띄우고, 엔진이 그 창을 캡처한다.
// 소리는 엔진의 church_app_audio(Core Audio 프로세스 탭)가 받는다.
// 재생은 송출 장면에 들어갈 때 처음부터 시작하고, 송출에서 빠지면 멈춘다. 반복이면 끝에서 다시 시작한다.
import AppKit
import SwiftUI
import WebKit
import Observation

enum YouTubeLink {
    private static let idPattern = #"^[A-Za-z0-9_-]{11}$"#

    /// youtu.be/ID · youtube.com/watch?v=ID · /shorts/ID · /embed/ID · /live/ID · ID 그대로
    static func videoID(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: idPattern, options: .regularExpression) != nil { return t }
        guard let c = URLComponents(string: t.lowercased().hasPrefix("http") ? t : "https://" + t),
              let host = c.host?.lowercased() else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        var id: String?
        if host.hasSuffix("youtu.be") { id = parts.first }
        else if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { id = v }
            else if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) { id = parts[1] }
        }
        guard let id, id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// ?t=90 · t=1m30s · start=90 → 초
    static func startSeconds(_ text: String) -> Int {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = c.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value else { return 0 }
        if let n = Int(raw.replacingOccurrences(of: "s", with: "")) { return max(n, 0) }
        var total = 0, number = 0
        for ch in raw {
            if let d = ch.wholeNumberValue { number = number * 10 + d; continue }
            switch ch { case "h": total += number * 3600; case "m": total += number * 60; case "s": total += number; default: break }
            number = 0
        }
        return max(total + number, 0)
    }

    static func thumbnail(_ id: String) -> URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

@MainActor
@Observable
final class YouTubePlayers {
    static let shared = YouTubePlayers()

    /// 소스별 상태 문구 (속성 패널에 표시)
    private(set) var status: [Source.ID: String] = [:]
    @ObservationIgnored private var players: [Source.ID: YouTubePlayerWindow] = [:]
    @ObservationIgnored private var playing: Set<Source.ID> = []
    @ObservationIgnored private var programIDs: Set<Source.ID> = []
    @ObservationIgnored private var projectorIDs: Set<Source.ID> = []

    /// 엔진이 캡처할 창 번호. 처음 부르면 플레이어 창을 만든다.
    func windowNumber(for source: Source) -> Int? {
        guard case let .youtube(url, loop) = source.config, let id = YouTubeLink.videoID(url) else { return nil }
        let start = YouTubeLink.startSeconds(url)
        if let p = players[source.id] {
            if p.videoID != id || p.start != start || p.loop != loop {
                p.configure(videoID: id, start: start, loop: loop)
                if playing.contains(source.id) { p.command("restart") }
            }
            return p.window.windowNumber
        }
        let p = YouTubePlayerWindow(videoID: id, start: start, loop: loop) { [weak self] text in
            self?.status[source.id] = text
        }
        players[source.id] = p
        return p.window.windowNumber
    }

    /// 송출(편집 중에는 편집 장면)에 들어 있는 유튜브만 재생. 새로 들어온 것은 처음부터.
    func live(_ ids: Set<Source.ID>) { programIDs = ids; apply() }
    /// 출력 창 장면에 들어 있는 유튜브도 재생
    func setProjector(_ ids: Set<Source.ID>) { projectorIDs = ids; apply() }

    private func apply() {
        let ids = programIDs.union(projectorIDs)
        for (id, p) in players {
            if ids.contains(id) { if !playing.contains(id) { p.command("restart") } }
            else if playing.contains(id) { p.command("pause") }
        }
        playing = ids.intersection(players.keys)
    }

    func restart(_ id: Source.ID) { players[id]?.command("restart") }
    func play(_ id: Source.ID) { players[id]?.command("play") }
    func pause(_ id: Source.ID) { players[id]?.command("pause") }
    func setLoop(_ id: Source.ID, _ loop: Bool) { players[id]?.setLoop(loop) }
    func togglePause(_ id: Source.ID) { players[id]?.command(players[id]?.wanted == "pause" ? "play" : "pause") }
    func isPaused(_ id: Source.ID) -> Bool { players[id]?.wanted == "pause" }

    /// 지운 소스의 플레이어 정리
    func prune(keep: Set<Source.ID>) {
        for id in players.keys where !keep.contains(id) {
            players[id]?.close(); players[id] = nil; status[id] = nil; playing.remove(id)
        }
    }

    func stopAll() { programIDs = []; projectorIDs = []; apply() }
}

/// WKScriptMessageHandler가 창을 붙잡지 않도록 약하게 연결
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlayerWindow?
    init(_ target: YouTubePlayerWindow) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message.body) }
    }
}

@MainActor
final class YouTubePlayerWindow: NSObject {
    let window: NSWindow
    private let web: WKWebView
    private(set) var videoID: String
    private(set) var start: Int
    private(set) var loop: Bool
    private(set) var wanted = "pause"
    private var ready = false
    private let report: (String) -> Void

    init(videoID: String, start: Int, loop: Bool, report: @escaping (String) -> Void) {
        self.videoID = videoID; self.start = start; self.loop = loop; self.report = report
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // 방송 화질에 맞춘 픽셀 크기 (Retina면 점 크기를 절반으로)
        let pixels = VideoQuality.running.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let rect = NSRect(x: 0, y: 0, width: pixels.width / scale, height: pixels.height / scale)
        let webView = WKWebView(frame: rect, configuration: config)
        // 다른 창에 가려져도 그리기를 멈추지 않게 (WebKit은 가려진 창의 그리기를 줄인다)
        // (비공개 설정이라 이름이 바뀌었을 수 있다 → 있을 때만, 정확한 KVC 이름으로. KVC는 "x"에 대해 _setX: 를 찾는다)
        if webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        let player = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        web = webView
        window = player
        super.init()
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "yt")
        player.contentView = webView
        player.isReleasedWhenClosed = false
        player.hasShadow = false
        player.ignoresMouseEvents = true
        player.backgroundColor = .black
        player.title = "Church OBS YouTube"
        player.isExcludedFromWindowsMenu = true
        player.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // 바탕화면 그림보다 뒤에 둔다: 사람 눈에는 보이지 않고, 화면 캡처(창 단위)는 가려진 창도 그대로 가져온다
        player.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.main { player.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY)) }
        player.orderBack(nil)
        load()
    }

    func configure(videoID: String, start: Int, loop: Bool) {
        self.videoID = videoID; self.start = start; self.loop = loop
        ready = false
        load()
    }

    func command(_ name: String) {
        wanted = name == "restart" ? "play" : name
        guard ready else { return }
        web.evaluateJavaScript("window.cmd && window.cmd('\(name)')", completionHandler: nil)
    }

    /// 반복만 바꾼다 (다시 불러오지 않는다)
    func setLoop(_ value: Bool) {
        loop = value
        if ready { web.evaluateJavaScript("LOOP=\(value ? "true" : "false")", completionHandler: nil) }
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        web.loadHTMLString("", baseURL: nil)
        window.orderOut(nil)
    }

    fileprivate func received(_ body: Any) {
        guard let text = body as? String else { return }
        if text == "ready" {
            ready = true
            report(L("준비됨"))
            if wanted == "play" { command("restart") }
        } else if text.hasPrefix("state:") {
            switch Int(text.dropFirst(6)) {
            case 1: report(L("재생 중"))
            case 2: report(L("멈춤"))
            case 3: report(L("불러오는 중…"))
            case 0: report(loop ? L("다시 재생") : L("끝남"))
            default: break
            }
        } else if text.hasPrefix("error:") {
            let code = Int(text.dropFirst(6)) ?? 0
            NSLog("[youtube-source] player error %d for %@", code, videoID)
            switch code {
            case 100: report(L("영상을 찾을 수 없습니다 (삭제되었거나 비공개)"))
            case 101, 150: report(L("이 영상은 다른 곳에서 재생할 수 없게 막혀 있습니다 (퍼가기 금지)"))
            case 153: report(L("유튜브가 재생을 거부했습니다 (153)"))
            default: report(L("재생하지 못했습니다") + " (\(code))")
            }
        }
    }

    private func load() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style></head>
        <body><div id="p"></div><script>
        var ID='\(videoID)',START=\(start),LOOP=\(loop ? "true" : "false"),player=null,ready=false,want='pause';
        function post(m){try{window.webkit.messageHandlers.yt.postMessage(m)}catch(e){}}
        function apply(){if(!ready)return;if(want==='restart'){player.seekTo(START,true);player.playVideo()}else if(want==='play'){player.playVideo()}else{player.pauseVideo()}}
        window.cmd=function(c){want=c;apply()};
        window.onYouTubeIframeAPIReady=function(){player=new YT.Player('p',{width:'100%',height:'100%',videoId:ID,
          playerVars:{autoplay:0,controls:0,rel:0,playsinline:1,iv_load_policy:3,disablekb:1,fs:0,modestbranding:1,start:START,origin:'https://churchobs.app'},
          events:{onReady:function(){ready=true;post('ready')},
                  onStateChange:function(e){post('state:'+e.data);if(e.data===0&&LOOP){player.seekTo(START,true);player.playVideo()}},
                  onError:function(e){post('error:'+e.data)}}})};
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://churchobs.app/"))
    }
}

/// 미디어 패널의 "유튜브" 탭: 주소를 붙여 넣고 장면에 넣기
struct YouTubeAddPanel: View {
    @Bindable var store: ShowStore
    @State private var link = ""
    @AppStorage("youtube.loop") private var loop = true

    var body: some View {
        let id = YouTubeLink.videoID(link)
        VStack(alignment: .leading, spacing: 10) {
            Text("유튜브에서 영상 주소를 복사해 붙여 넣으세요. (공유 › 복사, 또는 주소창)").font(.uiCaption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("유튜브 주소", text: $link, prompt: Text("https://youtu.be/…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("붙여넣기") { link = NSPasteboard.general.string(forType: .string) ?? link }
                    .controlSize(.small)
            }
            if let id, let thumb = YouTubeLink.thumbnail(id) {
                AsyncImage(url: thumb) { image in image.resizable().aspectRatio(16 / 9, contentMode: .fit) } placeholder: { Color.black.aspectRatio(16 / 9, contentMode: .fit) }
                    .frame(maxHeight: 170).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if !link.isEmpty {
                Text("유튜브 영상 주소가 아닙니다.").font(.uiCaption).foregroundStyle(.orange)
            }
            Toggle("끝나면 처음부터 반복", isOn: $loop)
            Button { add() } label: { Label("장면에 넣기", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity) }
                .churchProminentButton()
                .disabled(id == nil || store.selectedScene == nil)
            Text("송출 장면에 들어가면 처음부터 재생되고, 다른 장면으로 바꾸면 멈춥니다. 소리는 기본으로 방송과 현장 모두에 나갑니다. 퍼가기를 막은 영상은 재생되지 않습니다.")
                .font(.uiCaption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func add() {
        guard YouTubeLink.videoID(link) != nil, store.selectedScene != nil else { return }
        store.addNewSource(kind: .youtube, name: L("유튜브 영상"), config: .youtube(url: link.trimmingCharacters(in: .whitespacesAndNewlines), loop: loop))
        link = ""
    }
}
