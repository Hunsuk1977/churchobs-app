// SPDX-License-Identifier: GPL-2.0-or-later
// 진짜 WORDaLIVE 스튜디오를 앱 안에 띄운다. 사용 시간·요금은 모두 WORDaLIVE가 처리하고,
// Church OBS는 스튜디오의 "같은 컴퓨터 프로젝터·자막 창" 통로에 붙어 슬라이드·자막·배치를 받는다.
import SwiftUI
import AppKit
import WebKit
import CryptoKit

@MainActor @Observable
final class WordaliveStudioHost: NSObject {
    static let shared = WordaliveStudioHost()
    static let site = URL(string: "https://wordalive.app")!

    /// 로그인이 필요함 (스튜디오가 /auth 로 보냈거나 아직 연결 전)
    private(set) var needsLink = !UserDefaults.standard.bool(forKey: "wordalive.linked")
    private(set) var linking = false
    private(set) var linkMessage = ""
    private(set) var email = UserDefaults.standard.string(forKey: "wordalive.email") ?? ""
    /// 스튜디오 화면이 키보드를 받고 있나 (Space 같은 Church OBS 단축키를 양보)
    var webFocused = false

    @ObservationIgnored private(set) lazy var webView: StudioWebView = makeWebView()
    @ObservationIgnored private var urlWatch: NSKeyValueObservation?
    @ObservationIgnored private var verifier = ""
    @ObservationIgnored private var state = ""
    @ObservationIgnored private var urlObserver: NSObjectProtocol?
    @ObservationIgnored private var popups: [NSWindow] = []
    @ObservationIgnored private var loaded = false

    override init() {
        super.init()
        urlObserver = NotificationCenter.default.addObserver(forName: Notification.Name("WSOpenChurchOBSURL"), object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL, url.host == "wordalive" else { return }
            Task { @MainActor [weak self] in await self?.finishLink(url) }
        }
    }

    // MARK: 화면

    private func makeWebView() -> StudioWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // 로그인 상태를 앱을 다시 켜도 유지
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(WeakHandler(self), name: "churchobs")
        config.userContentController = controller
        let view = StudioWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.isInspectable = true   // 문제 확인용: Safari › 개발자용 메뉴에서 볼 수 있다
        view.setValue(false, forKey: "drawsBackground")
        view.onFocus = { [weak self] focused in self?.webFocused = focused }
        // SPA 안에서 주소가 바뀌어도 알 수 있게
        urlWatch = view.observe(\.url, options: [.new]) { [weak self] web, _ in
            let url = web.url
            Task { @MainActor [weak self] in self?.watch(url) }
        }
        return view
    }

    /// 화면에 처음 보일 때 스튜디오를 연다
    func appear() {
        guard !loaded, !needsLink else { return }
        loaded = true
        webView.load(URLRequest(url: Self.site.appendingPathComponent("studio")))
    }

    func reload() {
        if webView.url == nil || needsLink { loaded = false; appear() } else { webView.reload() }
    }

    func openStudio() { webView.load(URLRequest(url: Self.site.appendingPathComponent("studio"))) }

    /// 스튜디오에 덱 전체를 다시 달라고 하고, 이미 받은 그림은 서버와 대조해 바뀐 것만 새로 받는다
    func requestDeck() {
        webView.evaluateJavaScript("window.__churchobsRequestDeck && window.__churchobsRequestDeck()") { _, _ in }
        WordaliveFeed.shared.revalidateStored(force: true)
    }

    private func watch(_ url: URL?) {
        guard let url, url.host?.hasSuffix("wordalive.app") == true else { return }
        if url.path.hasPrefix("/auth") {
            // 앱 안에서는 Google 로그인이 막혀 있다 → Safari로 연결하게 안내
            setLinked(false)
            linkMessage = L("WORDaLIVE 로그인이 끝났습니다. 다시 연결해 주세요.")
        }
    }

    private func setLinked(_ on: Bool) {
        needsLink = !on
        UserDefaults.standard.set(on, forKey: "wordalive.linked")
    }

    // MARK: 계정 연결 (Safari에서 로그인 → 한 번 쓰는 코드 → 앱 안 스튜디오에 로그인 상태 전달)

    func startLink() {
        verifier = Self.random(32)
        state = Self.random(24)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var parts = URLComponents(url: Self.site.appendingPathComponent("connect/churchobs"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "challenge", value: challenge)]
        guard let url = parts.url else { return }
        linking = true
        linkMessage = L("Safari에서 WORDaLIVE에 로그인한 뒤 ‘연결’을 누르세요.")
        NSWorkspace.shared.open(url)
    }

    private func finishLink(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        defer { linking = false }
        guard !state.isEmpty, value("state") == state else { linkMessage = L("연결 요청이 맞지 않습니다. 다시 시도하세요."); return }
        state = ""
        if value("error") != nil { linkMessage = L("연결을 취소했습니다."); return }
        guard let code = value("code") else { linkMessage = L("연결 코드를 받지 못했습니다. 다시 시도하세요."); return }
        do {
            var request = URLRequest(url: Self.site.appendingPathComponent("api/public/churchobs/exchange"))
            request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
            let (data, response) = try await URLSession.shared.data(for: request)
            verifier = ""
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = body["access_token"] as? String, let refresh = body["refresh_token"] as? String
            else { linkMessage = L("연결하지 못했습니다. 다시 시도하세요."); return }
            email = (body["user"] as? [String: Any])?["email"] as? String ?? ""
            UserDefaults.standard.set(email, forKey: "wordalive.email")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let fragment = "access_token=\(access.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")&refresh_token=\(refresh.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            guard let session = URL(string: Self.site.appendingPathComponent("connect/churchobs/session").absoluteString + "#" + fragment) else { return }
            linkMessage = ""
            setLinked(true)
            loaded = true
            webView.load(URLRequest(url: session))   // 이 페이지가 로그인 상태를 저장하고 /studio 로 보낸다
        } catch {
            linkMessage = L("WORDaLIVE에 연결하지 못했습니다. 인터넷 연결을 확인하세요.")
        }
    }

    /// 이 Mac의 WORDaLIVE 로그인 정보를 지운다
    func unlink() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { $0.displayName.contains("wordalive") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {}
        }
        email = ""
        UserDefaults.standard.removeObject(forKey: "wordalive.email")
        setLinked(false)
        loaded = false
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        WordaliveFeed.shared.localEnded()
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: 스튜디오 → 앱 메시지

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        let feed = WordaliveFeed.shared
        switch type {
        case "owner", "log": NSLog("[wordalive] bridge %@", (m["text"] as? String) ?? "owner")
        case "deck": NSLog("[wordalive] bridge deck %ld", (m["images"] as? [String])?.count ?? -1); feed.localDeck(images: m["images"] as? [String] ?? [], index: m["index"] as? Int ?? 0)
        case "image": if let i = m["index"] as? Int, let data = m["data"] as? String { feed.localImage(index: i, dataURL: data) }
        case "slide": feed.localSlide(m["index"] as? Int ?? 0)
        case "blank": feed.localBlank(m["blank"] as? Bool ?? false)
        case "video": feed.localVideo(true)
        case "video-clear": feed.localVideo(false)
        case "subtitles": feed.localSubtitles(m["visible"] as? Bool ?? true)
        case "captionStyle": if let settings = m["settings"] as? [String: Any] { feed.localStyle(settings) }
        case "layout": feed.localLayout(m["layout"] as? String ?? "classic")
        case "captions":
            let entries = (m["entries"] as? [[String: Any]] ?? []).compactMap { e -> (String, String)? in
                guard let id = e["id"] as? String, let text = e["text"] as? String else { return nil }
                return (id, text)
            }
            feed.localCaptions(entries, reset: (m["mode"] as? String) == "seed")
        default: break
        }
    }

    /// 스튜디오 페이지에 넣는 연결 스크립트: 같은 컴퓨터 프로젝터·자막 창 통로에 붙어 받은 것을 앱으로 넘긴다
    static let bridgeScript = #"""
(() => {
  if (window.__churchobsBridge) return; window.__churchobsBridge = true;
  if (!/(^|\.)wordalive\.app$/.test(location.hostname)) return;
  const post = (m) => { try { window.webkit.messageHandlers.churchobs.postMessage(m); } catch (e) {} };
  const ownerId = () => {
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (!k || !k.startsWith('sb-') || !k.endsWith('-auth-token')) continue;
        const v = JSON.parse(localStorage.getItem(k) || 'null');
        const u = (v && v.user) || (v && v.currentSession && v.currentSession.user);
        if (u && u.id) return u.id;
      }
    } catch (e) {}
    return null;
  };
  let started = false, gotDeck = false, gotSettings = false, deck = null;
  const toDataURL = (url) => fetch(url).then(r => r.blob()).then(b => new Promise((res, rej) => {
    const fr = new FileReader(); fr.onload = () => res(fr.result); fr.onerror = rej; fr.readAsDataURL(b);
  }));
  const sendDeck = () => {
    const images = deck.images.map(u => (typeof u === 'string' && u.startsWith('blob:')) ? '' : (u || ''));
    post({ type: 'deck', images, index: deck.index || 0 });
    deck.images.forEach((u, i) => {
      if (typeof u === 'string' && u.startsWith('blob:')) toDataURL(u).then(d => post({ type: 'image', index: i, data: d })).catch(() => {});
    });
  };
  const start = (id) => {
    started = true;
    post({ type: 'owner', owner: id });
    post({ type: 'log', text: 'bridge started' });
    const ppt = new BroadcastChannel('wa-broadcast-ppt::' + id);
    ppt.onmessage = (ev) => {
      const d = ev.data || {};
      switch (d.type) {
        case 'images-start': deck = { tid: d.tid, index: d.index || 0, images: new Array(d.total || 0).fill('') }; break;
        case 'images-chunk': if (deck && d.tid === deck.tid) (d.chunk || []).forEach((u, i) => { deck.images[d.offset + i] = u; }); break;
        case 'images-end':
          if (deck && d.tid === deck.tid) {
            // 덱이 아직 덜 불러와져 전부 빈 그림이면 조금 뒤 다시 달라고 한다
            const real = deck.images.filter(u => typeof u === 'string' && u.length > 200 || /^https?:|^blob:/.test(u || '')).length;
            gotDeck = real > 0;
            sendDeck();
          }
          break;
        case 'slide':
          post({ type: 'slide', index: d.index || 0 });
          if (!gotDeck) ppt.postMessage({ type: 'ready' });   // 덱을 아직 못 받았으면 다시 달라고 한다
          break;
        case 'stage-blank': post({ type: 'blank', blank: !!d.blank }); break;
        case 'subtitle-visibility': post({ type: 'subtitles', visible: d.visible !== false }); break;
        case 'video': post({ type: 'video' }); break;
        case 'video-clear': post({ type: 'video-clear' }); break;
        case 'close': gotDeck = false; post({ type: 'deck', images: [], index: 0 }); break;
      }
    };
    const cap = new BroadcastChannel('wa-broadcast-preview::' + id);
    cap.onmessage = (ev) => {
      const d = ev.data || {};
      if (d.type === 'settings' && d.settings) {
        gotSettings = true;
        post({ type: 'layout', layout: d.settings.obsLayout || 'classic' });
        post({ type: 'captionStyle', settings: d.settings });   // 글꼴·크기·색·줄 수·타자 효과
      }
      else if (d.type === 'seed' || d.type === 'push') post({ type: 'captions', mode: d.type, entries: (d.entries || []).map(e => ({ id: String(e.id), text: String(e.text || '') })) });
      else if (d.type === 'subtitle-visibility') post({ type: 'subtitles', visible: d.visible !== false });
    };
    // 스튜디오가 나중에 열려도(페이지 이동) 받도록 인사를 되풀이한다
    const hello = () => {
      if (!location.pathname.startsWith('/studio')) { gotDeck = false; gotSettings = false; return; }
      if (!gotDeck) ppt.postMessage({ type: 'ready' });
      if (!gotSettings) cap.postMessage({ type: 'ready' });
    };
    hello();
    setInterval(hello, 2500);
    // 덱은 처음 한 번만 받으면 된다 → 못 받았을 때만 다시 요청 (슬라이드가 바뀌면 스튜디오가 알아서 보낸다)
    setInterval(() => { if (location.pathname.startsWith('/studio') && !gotDeck) ppt.postMessage({ type: 'request-deck-refresh' }); }, 30000);
    // 앱의 "덱 다시 받기" 버튼: 스튜디오에 덱 전체를 다시 달라고 한다
    window.__churchobsRequestDeck = () => { gotDeck = false; ppt.postMessage({ type: 'request-deck-refresh' }); ppt.postMessage({ type: 'ready' }); };
  };
  const wait = () => { if (started) return; const id = ownerId(); if (id) start(id); else setTimeout(wait, 1500); };
  wait();
})();
"""#
}

// MARK: - WebKit 위임

extension WordaliveStudioHost: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        do {
            guard let url, let host = url.host, ["http", "https"].contains(url.scheme ?? "") else { decisionHandler(.allow); return }
            if host.hasSuffix("wordalive.app") || host.hasSuffix("supabase.co") || action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
            if host.contains("accounts.google.com") || host.contains("appleid.apple.com") || host.contains("login.microsoftonline.com") || host.contains("lovable") {
                // 앱 안에서는 소셜 로그인을 할 수 없다 → Safari로 계정 연결
                decisionHandler(.cancel); startLink(); return
            }
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url); decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }

    // 마이크(번역기)·카메라: WORDaLIVE 페이지에만 허용
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host
        decisionHandler(host.hasSuffix("wordalive.app") ? .grant : .deny)
    }

    // 파일 올리기 (PPT·사진)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let multiple = parameters.allowsMultipleSelection, folders = parameters.allowsDirectories
        do {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = multiple
            panel.canChooseDirectories = folders
            panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        do {
            let alert = NSAlert(); alert.messageText = message; alert.runModal(); completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        do {
            let alert = NSAlert(); alert.messageText = message
            alert.addButton(withTitle: L("확인")); alert.addButton(withTitle: L("취소"))
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // 스튜디오가 여는 프로젝터·자막 창은 별도 창으로 그대로 연다
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        do {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
            popup.uiDelegate = self
            let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentView = popup
            window.title = "WORDaLIVE"
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            popups.removeAll { !$0.isVisible }
            popups.append(window)
            return popup
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
    }
}

/// 메시지 핸들러가 호스트를 붙잡아 두지 않도록
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var host: WordaliveStudioHost?
    init(_ host: WordaliveStudioHost) { self.host = host }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { host?.receive(body) }
    }
}

/// 키보드 초점을 알려 주는 웹 화면
final class StudioWebView: WKWebView {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder(); if ok { onFocus?(true) }; return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder(); if ok { onFocus?(false) }; return ok
    }
}

// MARK: - 진행 화면 왼쪽 패널

struct WordaliveStudioPane: View {
    var onHide: () -> Void = {}
    /// 자료 단계: 숨기기 단추 없이 꽉 찬 화면
    var fullscreen = false
    @State private var host = WordaliveStudioHost.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !fullscreen {
                    Button(action: onHide) { Image(systemName: "sidebar.left") }
                        .help(L("WORDaLIVE 스튜디오 숨기기"))
                }
                Text("WORDaLIVE 스튜디오").font(.uiHeadline)
                if !host.email.isEmpty, !host.needsLink {
                    Text(host.email).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !host.needsLink { SlideSignal() }
                if !host.needsLink {
                    SlideStoreChip()
                    Button { host.requestDeck() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                        .help(L("덱 다시 받기 — 스튜디오의 슬라이드를 다시 받고, 보관함 그림은 서버와 대조해 바뀐 것만 새로 받습니다"))
                    Button { host.openStudio() } label: { Image(systemName: "house") }.help("스튜디오 첫 화면")
                    Button { host.reload() } label: { Image(systemName: "arrow.clockwise") }.help("새로 고침")
                    Menu {
                        Button("덱 다시 받기") { host.requestDeck() }
                        Button("슬라이드 보관함 폴더 열기") { NSWorkspace.shared.activateFileViewerSelecting([WordaliveFeed.storeFolder]) }
                        Button("슬라이드 보관함 비우기", role: .destructive) { WordaliveFeed.shared.clearStore() }
                        Divider()
                        Button("Safari에서 다시 연결") { host.startLink() }
                        Button("이 Mac에서 WORDaLIVE 연결 해제", role: .destructive) { host.unlink() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if host.needsLink {
                linkPrompt
            } else {
                StudioWebContainer(view: host.webView)
                    .onAppear { host.appear() }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.panel, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
    }

    private var linkPrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "link.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("WORDaLIVE 계정을 연결하세요").font(.uiTitle3)
            Text("Safari에서 WORDaLIVE에 로그인하면 이 자리에 방송 스튜디오가 열립니다. 슬라이드·번역 사용 시간은 WORDaLIVE 계정에서 그대로 관리됩니다.")
                .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(host.linking ? L("Safari에서 기다리는 중…") : L("WORDaLIVE 계정 연결")) { host.startLink() }
                .churchProminentButton().controlSize(.large)
            if !host.linkMessage.isEmpty {
                Text(host.linkMessage).font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 스튜디오 → Church OBS 슬라이드가 실제로 넘어오고 있는지 한눈에
private struct SlideSignal: View {
    @State private var feed = WordaliveFeed.shared
    var body: some View {
        let ok = feed.slideCount > 0 && feed.slidesReady > 0 && feed.slideProblem.isEmpty
        HStack(spacing: 5) {
            Circle().fill(ok ? ChurchStatus.ok : (feed.slideProblem.isEmpty ? Color.secondary : .orange)).frame(width: 7, height: 7)
            Text(feed.slideProblem.isEmpty
                 ? (feed.slideCount > 0 ? "\(feed.slideIndex + 1)/\(feed.slideCount) · " + L("그림") + " \(feed.slidesReady)" : L("슬라이드 신호 없음"))
                 : feed.slideProblem)
                .font(.uiCaption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(L("Church OBS가 WORDaLIVE 스튜디오에서 받은 슬라이드"))
    }
}

/// 이 Mac에 저장된 슬라이드 그림(인터넷이 끊겨도 쓸 수 있는 것)
private struct SlideStoreChip: View {
    @State private var feed = WordaliveFeed.shared
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: feed.revalidating ? "arrow.triangle.2.circlepath" : "internaldrive")
                .font(.uiCaption2).foregroundStyle(.secondary)
            Text(feed.revalidating ? L("확인 중…") : L("보관함") + " \(feed.storedCount)")
                .font(.uiCaption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(feed.lastRefresh.map { L("이 Mac에 저장된 슬라이드 그림 · 마지막 확인 ") + $0.formatted(date: .omitted, time: .shortened) } ?? L("이 Mac에 저장된 슬라이드 그림 (인터넷이 끊겨도 보여 줍니다)"))
        .onAppear { feed.refreshStoredCount() }
    }
}

private struct StudioWebContainer: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> ZoomingBox { let box = ZoomingBox(); box.attach(view); return box }
    func updateNSView(_ box: ZoomingBox, context: Context) { if view.superview !== box { box.attach(view) } }
}

/// 스튜디오는 1320pt 너비에 맞춰 만들어져 있다 → 좁은 칸에서는 페이지를 살짝 줄여 한 화면에 다 보이게 한다
final class ZoomingBox: NSView {
    private weak var web: WKWebView?
    static let designWidth: CGFloat = 1320
    func attach(_ view: WKWebView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
        web = view
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let web, bounds.width > 100 else { return }
        let zoom = (min(1, max(0.68, bounds.width / Self.designWidth)) * 100).rounded() / 100
        if abs(web.pageZoom - zoom) > 0.01 { web.pageZoom = zoom }
    }
}
