// SPDX-License-Identifier: GPL-2.0-or-later
// WORDaLIVE 실시간 번역 자막을 받아 엔진의 자막 띠(church_captions)로 넘긴다.
// 읽기 전용(display 역할)이라 WORDaLIVE 로그인·토큰이 필요 없다.
import Foundation
import SwiftUI
import Observation
import CryptoKit

@MainActor @Observable
final class WordaliveFeed {
    static let shared = WordaliveFeed()

    /// 연결 안 함 · 번역 자막만(클라우드) · 슬라이드까지(앱 안 스튜디오)
    enum Mode: String, CaseIterable, Identifiable {
        case off, captions, studio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: L("연결 안 함")
            case .captions: L("번역 자막만")
            case .studio: L("슬라이드까지")
            }
        }
    }

    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "wordalive.mode") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "wordalive.on") ? .captions : .off) {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "wordalive.mode")
            switch mode {
            case .off: stop(); localEnded()
            case .captions: localEnded()
            case .studio: stop()   // 슬라이드까지: 앱 안 스튜디오에서 바로 받으므로 클라우드 연결은 쓰지 않는다
            }
        }
    }

    enum Status: Equatable {
        case off, resolving, waiting, connecting, connected, error(String)
    }

    /// 핸들(bae) · 핸들/장소(bae/v6) · 청중 링크(https://…/v/bae/v6)
    var link: String = UserDefaults.standard.string(forKey: "wordalive.link") ?? "" {
        didSet { UserDefaults.standard.set(link, forKey: "wordalive.link") }
    }
    private(set) var status: Status = .off
    private(set) var venueTitle = ""
    /// 번역 중인 진행자가 접속해 있나 (room:hello / room:host)
    private(set) var hostOnline = false
    private(set) var lastLine = ""
    private(set) var lastUpdate: Date?
    var isOn: Bool { status != .off }

    /// 엔진으로 보낼 곳: [{"t": 번역, "s": 원문}]
    @ObservationIgnored var sink: (([[String: String]]) -> Void)?
    /// 슬라이드 그림 (경로, 화면 끄기)
    @ObservationIgnored var slideSink: ((String, Bool) -> Void)?
    /// WORDaLIVE 스튜디오에서 1~5번 배치를 눌렀을 때
    @ObservationIgnored var layoutSink: ((String) -> Void)?

    // 슬라이드
    var slidesEnabled: Bool = UserDefaults.standard.object(forKey: "wordalive.slides") as? Bool ?? true {
        didSet { UserDefaults.standard.set(slidesEnabled, forKey: "wordalive.slides"); if !slidesEnabled { sendSlide("", false) } else { deckSignature = ""; showCurrentSlide() } }
    }
    var followLayout: Bool = UserDefaults.standard.object(forKey: "wordalive.followLayout") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followLayout, forKey: "wordalive.followLayout") }
    }
    private(set) var slideCount = 0
    private(set) var slideIndex = 0
    private(set) var slidesReady = 0
    private(set) var slideProblem = ""
    private(set) var layout = ""
    private(set) var stageSeen = false
    @ObservationIgnored private var slideIDs: [String] = []
    @ObservationIgnored private var slideBlank = false
    @ObservationIgnored private var slideFiles: [String: String] = [:]
    @ObservationIgnored private var slideURLs: [String: URL] = [:]
    @ObservationIgnored private var deckSignature = ""
    @ObservationIgnored private var deckTask: Task<Void, Never>?
    @ObservationIgnored private var lastDeckAttempt = Date.distantPast
    @ObservationIgnored private var lastSlideSent = ""
    @ObservationIgnored private var latestLines: [[String: String]] = []
    @ObservationIgnored private var subtitleVisible = true
    private static let site = "https://wordalive.app"
    /// 슬라이드 그림 보관함. 캐시 폴더는 macOS가 지울 수 있어 Application Support에 둔다 → 앱을 다시 켜도, 다음 주에도 그대로 쓴다
    private static let slideFolder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChurchOBS/wordalive-slides", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// 보관함에 이미 있는 그림은 다시 내려받지 않는다 (60일 넘게 안 쓴 것은 정리)
    private func adoptStoredSlides(_ ids: [String]) {
        let fm = FileManager.default
        for id in ids where slideFiles[id] == nil {
            let safe = id.replacingOccurrences(of: "/", with: "_")
            for ext in ["png", "img"] {
                let path = Self.slideFolder.appendingPathComponent("\(safe).\(ext)").path
                if fm.fileExists(atPath: path) { slideFiles[id] = path; try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path); break }
            }
        }
        if !prunedStore {
            prunedStore = true
            let cutoff = Date().addingTimeInterval(-60 * 86_400)
            for file in (try? fm.contentsOfDirectory(at: Self.slideFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }
    @ObservationIgnored private var prunedStore = false
    @ObservationIgnored private var deckIDSignature = ""

    // 보관함의 그림이 WORDaLIVE 쪽에서 같은 주소로 새로 구워졌을 수 있다(디자인 수정, 번역 줄
    // 스타일 변경) → 덱을 받을 때마다 ETag로 확인해 바뀐 것만 다시 받는다. 주소(경로)만으로
    // 키를 잡기 때문에 이 확인이 없으면 옛 그림이 60일 동안 남는다.
    @ObservationIgnored private var etags: [String: String] = {
        let url = WordaliveFeed.slideFolder.appendingPathComponent("etags.json")
        return (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }()
    private func saveEtags() {
        let url = Self.slideFolder.appendingPathComponent("etags.json")
        try? JSONEncoder().encode(etags).write(to: url)
    }
    /// 보관함에 있는 그림 수 (화면 표시용)
    private(set) var storedCount = 0
    private(set) var revalidating = false
    private(set) var lastRefresh: Date?
    func refreshStoredCount() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.slideFolder.path)) ?? []
        storedCount = files.filter { $0.hasSuffix(".png") || $0.hasSuffix(".img") }.count
    }
    /// 보관함 비우기 — 다음 덱부터 전부 새로 받는다
    func clearStore() {
        deckTask?.cancel(); deckTaskDone = true
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.slideFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        slideFiles = [:]; etags = [:]; slidesReady = 0; storedCount = 0; deckIDSignature = ""
        lastSlideSent = ""
        showCurrentSlide()
        if !slideIDs.isEmpty {
            let ids = slideIDs
            deckTaskDone = false
            deckTask = Task { [weak self] in await self?.downloadAll(ids); self?.deckTaskDone = true }
        }
    }
    static var storeFolder: URL { slideFolder }
    /// 이미 받은 그림이 서버에서 바뀌었는지 확인하고(ETag) 바뀐 것만 다시 받는다. force = 전부 다시
    func revalidateStored(force: Bool = false) {
        let ids = slideIDs.filter { slideFiles[$0] != nil && slideURLs[$0] != nil }
        guard !ids.isEmpty, !revalidating else { return }
        revalidating = true
        Task { [weak self] in
            guard let self else { return }
            var changed = 0
            for id in ids {
                if Task.isCancelled { break }
                if await self.redownloadIfChanged(id, force: force) { changed += 1 }
            }
            self.revalidating = false
            self.lastRefresh = Date()
            self.refreshStoredCount()
            if changed > 0 {
                NSLog("[wordalive] %ld slide(s) re-downloaded (changed on server)", changed)
                self.lastSlideSent = ""   // 같은 경로라도 그림이 바뀌었으니 엔진에 다시 보낸다
                self.showCurrentSlide()
            }
        }
    }
    /// 서버 ETag가 다르면(또는 force) 그림을 새로 받는다. 받았으면 true
    private func redownloadIfChanged(_ id: String, force: Bool) async -> Bool {
        guard let url = slideURLs[id] else { return false }
        var request = URLRequest(url: url)
        if !force, let tag = etags[id] { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (temp, response) = try await Self.downloader.download(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 304 { return false }
            guard http.statusCode == 200 else { return false }
            let safe = id.replacingOccurrences(of: "/", with: "_")
            let target = Self.slideFolder.appendingPathComponent("\(safe).png")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            slideFiles[id] = target.path
            if let tag = http.value(forHTTPHeaderField: "ETag") { etags[id] = tag; saveEtags() }
            return true
        } catch { return false }
    }

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var room = ""
    @ObservationIgnored private var fixedVenue = false
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var backoff: TimeInterval = 2
    @ObservationIgnored private var lastSent: [[String: String]] = []
    @ObservationIgnored private var lastResolve = Date.distantPast

    private static let relay = "wss://wordalive-realtime.baehs.workers.dev"
    private static let supabase = "https://buqeabpfmakttstknrxx.supabase.co"
    /// 공개(anon) 키 — WORDaLIVE 웹앱에도 그대로 들어 있는 값
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1cWVhYnBmbWFrdHRzdGtucnh4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2OTk3NzgsImV4cCI6MjA5MjI3NTc3OH0.Da59lQcQ1J1-7SyXTkFXy4z8njKs8Z7CPOaM3C19k5o"

    var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "wordalive.on") }
        set { UserDefaults.standard.set(newValue, forKey: "wordalive.on") }
    }

    var statusText: String {
        if localActive { return L("앱 안의 WORDaLIVE 스튜디오와 연결됨") + (hostOnline || !localEntries.isEmpty ? "" : " · " + L("번역 시작을 기다리는 중")) }
        return switch status {
        case .off: L("WORDaLIVE 번역 화면의 자막을 방송에 띄웁니다")
        case .resolving: L("WORDaLIVE 확인 중…")
        case .waiting: L("열린 번역 세션이 없습니다 · 번역을 시작하면 자동으로 연결됩니다")
        case .connecting: L("자막 서버에 연결 중…")
        case .connected:
            hostOnline ? L("연결됨 · 자막 받는 중") + (venueTitle.isEmpty ? "" : " · \(venueTitle)")
                       : L("연결됨 · 번역 시작을 기다리는 중") + (venueTitle.isEmpty ? "" : " · \(venueTitle)")
        case .error(let m): m
        }
    }

    // MARK: 시작·중지

    func start() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = .error(L("WORDaLIVE 핸들이나 예배 링크를 입력하세요.")); return }
        autoStart = true
        disconnect()
        backoff = 2
        Task { await resolveAndConnect() }
    }

    func stop() {
        autoStart = false
        disconnect()
        status = .off
        hostOnline = false
        lastLine = ""
        push([])
        deckTask?.cancel(); deckTask = nil
        deckSignature = ""; slideIDs = []; slideCount = 0; slidesReady = 0; layout = ""; stageSeen = false
        sendSlide("", false)
    }

    private func disconnect() {
        retryWork?.cancel(); retryWork = nil
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
    }

    // MARK: 방 찾기

    private func parse(_ text: String) -> (handle: String, slug: String?) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), url.host != nil {
            var parts = url.pathComponents.filter { $0 != "/" }
            if let v = parts.firstIndex(of: "v") { parts = Array(parts[(v + 1)...]) }
            t = parts.joined(separator: "/")
        }
        if t.hasPrefix("@") { t.removeFirst() }
        let parts = t.split(separator: "/").map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : nil)
    }

    private func rpc(_ name: String, _ body: [String: String]) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "\(Self.supabase)/rest/v1/rpc/\(name)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func roomName(_ sessionKey: String) -> String {
        sessionKey.hasPrefix("prompter:") ? String(sessionKey.dropFirst("prompter:".count)) : sessionKey
    }

    private func resolveAndConnect() async {
        guard autoStart else { return }
        status = .resolving
        lastResolve = Date()
        let (handle, slug) = parse(link)
        guard !handle.isEmpty else { status = .error(L("WORDaLIVE 핸들이나 예배 링크를 입력하세요.")); return }
        do {
            if let slug {
                let rows = try await rpc("get_venue_public_by_slug", ["p_handle": handle, "p_slug": slug])
                guard let row = rows.first, let key = row["session_key"] as? String else {
                    status = .error(L("이 WORDaLIVE 예배 링크를 찾지 못했습니다.")); return
                }
                fixedVenue = true
                venueTitle = row["title"] as? String ?? ""
                connect(roomName(key))
            } else {
                let rows = try await rpc("get_open_sessions_by_handle", ["p_handle": handle])
                fixedVenue = false
                guard let row = rows.first, let key = row["session_key"] as? String else {
                    status = .waiting
                    scheduleRetry(15, resolve: true)
                    return
                }
                venueTitle = row["venue_title"] as? String ?? ""
                connect(roomName(key))
            }
        } catch {
            status = .error(L("WORDaLIVE에 연결하지 못했습니다. 인터넷 연결을 확인하세요."))
            scheduleRetry(min(backoff, 30), resolve: true)
            backoff = min(backoff * 2, 30)
        }
    }

    // MARK: 릴레이

    private func connect(_ newRoom: String) {
        guard autoStart else { return }
        disconnect()
        room = newRoom
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let encoded = newRoom.addingPercentEncoding(withAllowedCharacters: allowed) ?? newRoom
        guard let url = URL(string: "\(Self.relay)/room/\(encoded)?role=display") else { return }
        status = .connecting
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(socket)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepAlive() }
        }
    }

    private func keepAlive() {
        task?.send(.string("ping")) { _ in }
        // 핸들만 입력한 경우: 새 번역 세션으로 바뀌었는지 1분마다 확인
        if !fixedVenue, Date().timeIntervalSince(lastResolve) > 60 {
            lastResolve = Date()
            let (handle, _) = parse(link)
            Task {
                guard let rows = try? await rpc("get_open_sessions_by_handle", ["p_handle": handle]),
                      let key = rows.first?["session_key"] as? String else { return }
                if roomName(key) != room { connect(roomName(key)) }
            }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === socket else { return }
                switch result {
                case .failure:
                    self.hostOnline = false
                    self.status = .connecting
                    self.scheduleRetry(min(self.backoff, 30), resolve: !self.fixedVenue)
                    self.backoff = min(self.backoff * 2, 30)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    else if case .data(let data) = message, let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    self.receive(socket)
                }
            }
        }
    }

    private func handle(_ text: String) {
        if text == "pong" { return }
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = frame["e"] as? String else { return }
        let payload = frame["p"] as? [String: Any]
        if status != .connected { status = .connected; backoff = 2 }
        switch event {
        case "room:hello", "room:host":
            if let has = payload?["hasHost"] as? Bool { hostOnline = has }
            else if let present = payload?["present"] as? Bool {
                hostOnline = present
                if !present { push([]) }   // 번역이 끝나면 자막을 내린다
            }
        case "snapshot":
            hostOnline = true
            if localActive { return }   // 같은 컴퓨터의 스튜디오에서 직접 받고 있으면 클라우드 사본은 쓰지 않는다
            if let lines = payload?["lines"] as? [[String: Any]] {
                latestLines = lines.suffix(3).compactMap { line -> [String: String]? in
                    let t = (line["translated"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let s = (line["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty && s.isEmpty ? nil : ["t": t, "s": s]
                }
            }
            let deck = payload?["deck"] as? [String: Any]
            subtitleVisible = deck?["subtitleVisible"] as? Bool ?? true   // 스튜디오의 ‘자막 숨기기’
            push(subtitleVisible ? latestLines : [])
            handleStage(deck: deck, stage: payload?["stage"] as? [String: Any])
        default: break
        }
    }

    // MARK: 슬라이드·배치

    private func handleStage(deck: [String: Any]?, stage: [String: Any]?) {
        guard mode == .studio else { return }   // ‘번역 자막만’은 자막만 받는다
        if let stage {
            stageSeen = true
            slideBlank = stage["blank"] as? Bool ?? false
            if let next = stage["layout"] as? String, next != layout {
                layout = next
                if followLayout, next != "classic" { layoutSink?(next) }
            }
        }
        guard let deck else { return }
        let ids = (deck["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        slideIDs = ids
        slideCount = ids.count
        slideIndex = max(0, min(deck["current"] as? Int ?? 0, max(ids.count - 1, 0)))
        guard slidesEnabled else { return }
        let signature = ids.joined(separator: "|")
        if signature != deckSignature, !ids.isEmpty, Date().timeIntervalSince(lastDeckAttempt) > 20 {
            deckSignature = signature
            loadDeck(ids)
        }
        showCurrentSlide()
    }

    private var ownerID: String { String(room.split(separator: ":").first ?? "") }

    /// 서명된 슬라이드 주소를 받고, 지금 슬라이드부터 차례로 내려받는다
    private func loadDeck(_ ids: [String]) {
        deckTask?.cancel()
        lastDeckAttempt = Date()
        let owner = ownerID
        deckTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: URL(string: "\(Self.site)/api/public/obs-deck")!)
                request.httpMethod = "POST"; request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["ownerId": owner, "ids": ids])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let urls = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["urls"] as? [String: String]
                else { self.slideProblem = L("슬라이드 그림을 받지 못했습니다. WORDaLIVE를 퍼블리시했는지 확인하세요."); self.deckSignature = ""; return }
                if urls.isEmpty { self.slideProblem = L("저장된 덱의 슬라이드가 없습니다. WORDaLIVE 스튜디오에서 덱을 저장하세요.") ; return }
                self.slideProblem = ""
                for (id, link) in urls { if let u = URL(string: link) { self.slideURLs[id] = u } }
                self.slidesReady = ids.filter { self.slideFiles[$0] != nil }.count
                await self.downloadAll(ids)
            } catch {
                self.slideProblem = L("슬라이드 그림을 받지 못했습니다. 인터넷 연결을 확인하세요.")
                self.deckSignature = ""
            }
        }
    }

    /// 지금 슬라이드 → 그다음부터 차례로 → 앞쪽. 넘기는 사이에 지금 슬라이드가 바뀌면 그것부터
    private func downloadAll(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let start = min(slideIndex, ids.count - 1)
        var queue = (Array(ids[start...]) + Array(ids[..<start])).filter { slideFiles[$0] == nil && !$0.hasPrefix("empty-") }
        var failed = 0
        while !queue.isEmpty {
            if Task.isCancelled { return }
            // 지금 보고 있는 슬라이드가 아직이면 그것부터, 그다음 세 장씩 함께
            let current = slideIDs.indices.contains(slideIndex) ? slideIDs[slideIndex] : nil
            var batch: [String] = []
            if let current, slideFiles[current] == nil, let i = queue.firstIndex(of: current) { batch.append(queue.remove(at: i)) }
            while batch.count < 3, !queue.isEmpty { batch.append(queue.removeFirst()) }
            let results = await withTaskGroup(of: (String, Bool).self, returning: [(String, Bool)].self) { group in
                for id in batch { group.addTask { @MainActor in (id, await self.download(id)) } }
                var out: [(String, Bool)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, ok) in results where !ok {
                failed += 1
                if failed <= ids.count * 2 { queue.append(id) }   // 실패한 장은 뒤로 돌려 다시 시도
            }
            if results.contains(where: { !$0.1 }) { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        if slideProblem.hasPrefix(L("슬라이드 그림을 내려받지 못했습니다")) && slidesReady == ids.filter({ !$0.hasPrefix("empty-") }).count { slideProblem = "" }
    }

    @discardableResult
    private func download(_ id: String) async -> Bool {
        if slideFiles[id] != nil { return true }
        if let dataURL = slideData[id] {
            // 저장 전 슬라이드(data:)는 바로 풀어 쓴다
            guard let comma = dataURL.firstIndex(of: ","), let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return false }
            let target = Self.slideFolder.appendingPathComponent("\(id).img")
            guard (try? bytes.write(to: target)) != nil else { return false }
            slideFiles[id] = target.path; slidesReady = slideIDs.filter { slideFiles[$0] != nil }.count; showCurrentSlide()
            return true
        }
        guard let url = slideURLs[id] else { return false }
        do {
            let (temp, response) = try await Self.downloader.download(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                NSLog("[wordalive] slide download failed HTTP %ld (%@)", code, url.host ?? "")
                slideProblem = L("슬라이드 그림을 내려받지 못했습니다") + " (HTTP \(code))"
                return false
            }
            let safe = id.replacingOccurrences(of: "/", with: "_")
            let target = Self.slideFolder.appendingPathComponent("\(safe).png")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            slideFiles[id] = target.path
            if let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") { etags[id] = tag; saveEtags() }
            slidesReady = slideIDs.filter { slideFiles[$0] != nil }.count
            storedCount += 1
            showCurrentSlide()
            return true
        } catch {
            NSLog("[wordalive] slide download error %@", error.localizedDescription)
            slideProblem = L("슬라이드 그림을 내려받지 못했습니다") + " · " + error.localizedDescription
            return false
        }
    }
    /// 그림 내려받기 전용 세션: 느린 인터넷에서도 끊기지 않게 넉넉한 시간
    private static let downloader: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 180
        c.httpMaximumConnectionsPerHost = 4
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    private func showCurrentSlide() {
        guard mode == .studio, slideIDs.indices.contains(slideIndex) else { return }
        let blank = slideBlank || localVideoOn
        if let path = slideFiles[slideIDs[slideIndex]] { sendSlide(path, blank) }
        else if slideIDs[slideIndex].hasPrefix("empty-") { sendSlide("", blank) }
        else { sendSlide(lastSlidePath, blank) }   // 아직 못 받았으면 지난 그림 유지
    }
    @ObservationIgnored private var lastSlidePath = ""
    private func sendSlide(_ path: String, _ blank: Bool) {
        let key = "\(path)|\(blank)"
        guard key != lastSlideSent else { return }
        NSLog("[wordalive] show slide %@ blank=%ld", (path as NSString).lastPathComponent, blank ? 1 : 0)
        lastSlideSent = key; lastSlidePath = path
        slideSink?(path, blank)
    }

    // MARK: 앱 안 스튜디오 (같은 컴퓨터 프로젝터·자막 통로)

    private(set) var localActive = false
    @ObservationIgnored private var localEntries: [(id: String, text: String)] = []
    @ObservationIgnored private var localVideoOn = false
    @ObservationIgnored private var slideData: [String: String] = [:]

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 스튜디오가 덱 전체(그림 주소 목록)를 보냈을 때
    func localDeck(images: [String], index: Int) {
        guard mode == .studio else { return }
        localActive = true
        slideProblem = ""
        var ids: [String] = []
        for (i, source) in images.enumerated() {
            if let url = URL(string: source), url.scheme == "https" {
                // 서명 주소는 매번 달라지므로 경로로 알아본다
                let key = "u-" + Self.digest((url.host ?? "") + url.path)
                slideURLs[key] = url; ids.append(key)
            } else if source.hasPrefix("data:") {
                let key = "d-" + Self.digest(source)
                slideData[key] = source; ids.append(key)
            } else {
                ids.append("empty-\(i)")
            }
        }
        slideIDs = ids
        slideCount = ids.count
        slideIndex = max(0, min(index, max(ids.count - 1, 0)))
        adoptStoredSlides(ids)
        slidesReady = ids.filter { slideFiles[$0] != nil }.count
        showCurrentSlide()
        // 같은 덱이 다시 오면(스튜디오가 30초마다 되보냄) 받던 것을 끊지 않고 그대로 이어 간다
        let signature = ids.joined(separator: "|")
        let stillRunning = deckTask != nil && !deckTaskDone
        if signature == deckIDSignature && stillRunning { return }
        deckIDSignature = signature
        NSLog("[wordalive] deck %ld slides, now %ld, %ld already here", ids.count, slideIndex + 1, slidesReady)
        deckTask?.cancel()
        deckTaskDone = false
        deckTask = Task { [weak self] in
            await self?.downloadAll(ids)
            self?.deckTaskDone = true
            // 보관함에서 꺼내 쓴 그림이 서버에서 새로 구워졌는지 확인
            self?.revalidateStored()
        }
    }
    @ObservationIgnored private var deckTaskDone = true

    /// 저장 전 슬라이드(blob:) 그림이 따로 왔을 때
    func localImage(index: Int, dataURL: String) {
        guard mode == .studio else { return }
        guard slideIDs.indices.contains(index) else { return }
        let key = "d-" + Self.digest(dataURL)
        slideData[key] = dataURL
        slideIDs[index] = key
        Task { await download(key) }
    }

    func localSlide(_ index: Int) {
        guard mode == .studio else { return }
        NSLog("[wordalive] slide %ld of %ld", index + 1, slideIDs.count)
        localActive = true
        slideIndex = max(0, min(index, max(slideIDs.count - 1, 0)))
        showCurrentSlide()
    }
    func localBlank(_ blank: Bool) { guard mode == .studio else { return }; localActive = true; slideBlank = blank; showCurrentSlide() }
    func localVideo(_ on: Bool) { guard mode == .studio else { return }; localVideoOn = on; showCurrentSlide() }
    func localSubtitles(_ visible: Bool) {
        guard mode == .studio else { return }
        localActive = true
        subtitleVisible = visible
        push(visible ? localLines : [])
    }
    func localLayout(_ next: String) {
        guard mode == .studio else { return }
        localActive = true
        stageSeen = true
        guard next != layout else { return }
        layout = next
        if followLayout, next != "classic" { layoutSink?(next) }
    }
    func localCaptions(_ entries: [(String, String)], reset: Bool) {
        guard mode == .studio else { return }
        localActive = true
        hostOnline = true
        if reset { localEntries = [] }
        for (id, text) in entries {
            if let i = localEntries.firstIndex(where: { $0.id == id }) { localEntries[i].text = text } else { localEntries.append((id, text)) }
        }
        localEntries = Array(localEntries.suffix(6))
        if subtitleVisible { push(localLines) }
    }
    private var localLines: [[String: String]] {
        localEntries.suffix(3).compactMap { e in
            let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : ["t": t, "s": ""]
        }
    }
    /// 자료 소스를 WORDaLIVE로 되돌렸을 때: 지금 슬라이드를 엔진에 다시 보낸다
    func resendSlide() {
        lastSlideSent = ""
        showCurrentSlide()
    }

    /// 연결 해제·스튜디오 닫힘
    func localEnded() {
        localActive = false
        localEntries = []
        clearStyle()
        push([])
        sendSlide("", false)
    }

    private func push(_ lines: [[String: String]]) {
        guard lines != lastSent else { return }
        lastSent = lines
        lastLine = lines.last?["t"] ?? ""
        lastUpdate = Date()
        typedLines = lines
        let newest = lines.last?["t"] ?? ""
        if newest != typedTarget {
            // 같은 문장이 이어서 늘어난 것이면 이미 보인 데까지는 그대로, 새 문장이면 처음부터 타자
            let shown = String(typedTarget.prefix(typedCount))
            if typedCount == 0 || !newest.hasPrefix(shown) { typedCount = 0 }
            typedTarget = newest
        }
        if typeMode == "line" || typeMode == "vivid" || newest.isEmpty { typedCount = newest.count }
        emitTyped()
        if typedCount < typedTarget.count, typeTimer == nil {
            let interval = max(typeMode == "char" ? 0.025 : 0.045, typeSpeed)
            typeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.typeStep() }
            }
        }
    }

    // MARK: 타자 효과 (WORDaLIVE 자막처럼 최신 문장이 단어 단위로 나타난다)

    @ObservationIgnored private var typeMode = "word"
    @ObservationIgnored private var typeSpeed: TimeInterval = 0.045
    @ObservationIgnored private var typeTimer: Timer?
    @ObservationIgnored private var typedLines: [[String: String]] = []
    @ObservationIgnored private var typedTarget = ""
    @ObservationIgnored private var typedCount = 0

    private func typeStep() {
        let chars = Array(typedTarget)
        guard typedCount < chars.count else { typeTimer?.invalidate(); typeTimer = nil; return }
        if typeMode == "char" {
            typedCount += 1
        } else {
            // 다음 단어 끝까지 (한 번에 한 단어)
            var i = typedCount
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            typedCount = max(i, typedCount + 1)
        }
        emitTyped()
    }

    private func emitTyped() {
        var out = typedLines
        if !out.isEmpty { out[out.count - 1]["t"] = String(typedTarget.prefix(typedCount)) }
        sink?(out)
    }

    // MARK: WORDaLIVE 자막 디자인

    /// WORDaLIVE 스튜디오의 자막 디자인을 따르는 중
    private(set) var styleActive = false
    /// 엔진으로: captionStyle 명령 인자
    @ObservationIgnored var styleSink: (([String: Any]) -> Void)?
    @ObservationIgnored private var lastStyle: [String: Any] = [:]

    func localStyle(_ s: [String: Any]) {
        guard mode == .studio else { return }
        func num(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue ?? Double(s[k] as? String ?? "") }
        if let tw = s["tw"] as? String { typeMode = tw }
        if let ts = num("ts") { typeSpeed = ts / 1000 }
        let style: [String: Any] = [
            "active": true,
            "family": s["font"] as? String ?? "",
            "weight": Int(num("fw") ?? 600),
            "size": num("size") ?? 26,
            "lines": Int(num("lines") ?? 3),
            "content": num("cw") ?? 100,
            "fg": Self.cssColor(s["fg"] as? String) ?? [1, 1, 1, 1],
            "bg": Self.cssColor(s["bg"] as? String) ?? [0, 0, 0, 0.55],
        ]
        guard !NSDictionary(dictionary: style).isEqual(to: lastStyle) else { return }
        lastStyle = style
        styleActive = true
        styleSink?(style)
    }

    private func clearStyle() {
        guard styleActive else { return }
        styleActive = false; lastStyle = [:]; typeMode = "word"; typeSpeed = 0.045
        styleSink?(["active": false])
    }

    /// "#fff", "#ffffff", "#ffffffcc", "rgb(…)", "rgba(…)", "transparent" → [r, g, b, a] (0~1)
    static func cssColor(_ text: String?) -> [Double]? {
        guard var t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t == "transparent" { return [0, 0, 0, 0] }
        if t.hasPrefix("#") {
            t.removeFirst()
            if t.count == 3 || t.count == 4 { t = t.map { "\($0)\($0)" }.joined() }
            guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
            let hasA = t.count == 8
            let r = Double((v >> (hasA ? 24 : 16)) & 0xff) / 255, g = Double((v >> (hasA ? 16 : 8)) & 0xff) / 255
            let b = Double((v >> (hasA ? 8 : 0)) & 0xff) / 255, a = hasA ? Double(v & 0xff) / 255 : 1
            return [r, g, b, a]
        }
        if t.hasPrefix("rgb"), let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")") {
            let parts = t[t.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            return [parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? min(max(parts[3], 0), 1) : 1]
        }
        return nil
    }

    private func scheduleRetry(_ delay: TimeInterval, resolve: Bool) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.autoStart else { return }
                if resolve || self.room.isEmpty { await self.resolveAndConnect() } else { self.connect(self.room) }
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - 화면

/// 자막 연결 상태 한 줄 (장면 편집 속성·소스 추가 창)
struct CaptionsStatusRow: View {
    @State private var feed = WordaliveFeed.shared
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(feed.statusText).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private var color: Color {
        switch feed.status {
        case .connected: feed.hostOnline ? ChurchStatus.ok : .orange
        case .off: .secondary.opacity(0.5)
        case .error: .red
        default: .orange
        }
    }
}

/// 준비 화면: WORDaLIVE 핸들·예배 링크 입력과 연결
struct WordaliveSetup: View {
    let store: ShowStore
    @State private var feed = WordaliveFeed.shared
    @State private var host = WordaliveStudioHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("WORDaLIVE", selection: $feed.mode) {
                ForEach(WordaliveFeed.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch feed.mode {
            case .off:
                EmptyView()
            case .captions: captionsSetup
            case .studio: studioSetup
            }
        }
    }

    /// 번역 자막만: 다른 컴퓨터·휴대폰에서 번역해도 클라우드로 자막만 받는다
    private var captionsSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("WORDaLIVE", text: $feed.link, prompt: Text("핸들 또는 예배 링크 (예: bae/v6)"))
                .textFieldStyle(.roundedBorder)
                .disabled(feed.isOn)
                .onSubmit { feed.start() }
            lastLine

        }
    }

    /// 슬라이드까지: 계정 한 줄 + 배치 따라가기. 장면 만들기는 아직 없을 때만
    private var studioSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(host.needsLink ? Color.orange : ChurchStatus.ok).frame(width: 8, height: 8)
                Group {
                    if host.needsLink { Text("계정 연결 필요") }
                    else {
                        Text(host.email.isEmpty ? L("계정 연결됨") : host.email)
                        + Text(feed.slideCount > 0 ? "  ·  " + L("슬라이드") + " \(feed.slideCount)" : "")
                    }
                }
                .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if host.needsLink {
                    Button(host.linking ? L("Safari에서 기다리는 중…") : L("WORDaLIVE 계정 연결")) { host.startLink() }
                }
            }
            if !feed.slideProblem.isEmpty {
                Text(feed.slideProblem).font(.uiCaption).foregroundStyle(.orange)
            }
            Toggle("1~5번 배치를 따라 장면 바꾸기", isOn: $feed.followLayout).toggleStyle(.switch).font(.uiCaption)
            if store.wordaliveScenesReady < 5 {
                Button("WORDaLIVE 장면 만들기") { store.buildWordaliveScenes() }
                    .help(L("카메라·슬라이드·자막을 1~5번 배치대로 놓은 장면 5개를 만듭니다"))
            }
        }
    }

    @ViewBuilder private var lastLine: some View {
        if !feed.lastLine.isEmpty {
            Text("“\(feed.lastLine)”").font(.uiCaption).lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
        }
    }
}

// MARK: - WORDaLIVE 배치(1~5) ↔ 장면

extension ShowStore {
    /// WORDaLIVE obsLayouts.ts 의 1280×720 배치를 그대로 옮긴 정규화 좌표
    struct WordaliveLayout {
        let id: String
        let name: String
        let camera: CGRect?
        let slide: CGRect?
        let caption: CGRect
        let boxCaption: Bool
    }
    static var wordaliveLayouts: [WordaliveLayout] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x / 1280, y: y / 720, width: w / 1280, height: h / 720) }
        return [
            .init(id: "split-left", name: L("WL ① 왼쪽 슬라이드 + 자막"), camera: r(704, 0, 576, 720), slide: r(0, 0, 704, 396), caption: r(0, 396, 704, 324), boxCaption: true),
            .init(id: "split-right", name: L("WL ② 오른쪽 슬라이드 + 자막"), camera: r(0, 0, 576, 720), slide: r(576, 0, 704, 396), caption: r(576, 396, 704, 324), boxCaption: true),
            .init(id: "pip", name: L("WL ③ 작은 슬라이드 + 하단 자막"), camera: r(0, 0, 1280, 720), slide: r(832, 24, 424, 239), caption: r(0, 528, 1280, 192), boxCaption: false),
            .init(id: "lower-third", name: L("WL ④ 하단 자막만"), camera: r(0, 0, 1280, 720), slide: nil, caption: r(0, 500, 1280, 220), boxCaption: false),
            .init(id: "fullscreen", name: L("WL ⑤ 슬라이드 전체 + 하단 자막"), camera: nil, slide: r(0, 0, 1280, 540), caption: r(0, 540, 1280, 180), boxCaption: false),
        ]
    }

    private static let wordaliveKey = "wordalive.scenes"
    var wordaliveSceneMap: [String: UUID] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: Self.wordaliveKey) as? [String: String] ?? [:]
            return raw.compactMapValues(UUID.init(uuidString:)).filter { pair in scenes.contains { $0.id == pair.value } }
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.uuidString), forKey: Self.wordaliveKey) }
    }
    var wordaliveScenesReady: Int { wordaliveSceneMap.count }

    /// 없는 배치 장면만 새로 만든다 (이미 있는 장면은 목사님이 고친 그대로 둔다). 만든 개수를 돌려준다
    @discardableResult
    func buildWordaliveScenes() -> Int {
        guard !editingLocked else { return 0 }
        func reuse(_ kind: SourceKind, where match: (SourceConfig) -> Bool = { _ in true }, make: () -> Source) -> Source.ID {
            if let s = sources.first(where: { $0.kind == kind && match($0.config) }) { return s.id }
            let s = make(); sources.append(s); return s.id
        }
        if mainCameraSourceID == nil {
            let s = Source(name: L("카메라 · 강단"), kind: .camera); sources.append(s); mainCameraSourceID = s.id
        }
        if mainMicSourceID == nil {
            let s = Source(name: L("강단 마이크"), kind: .audio); sources.append(s); mainMicSourceID = s.id
        }
        guard let camera = mainCameraSourceID, let mic = mainMicSourceID else { return 0 }
        let slide = reuse(.slides) { Source(name: L("WORDaLIVE 슬라이드"), kind: .slides, config: .slides) }
        let band = reuse(.captions, where: { config in if case let .captions(_, _, _, lines) = config { return lines < 3 }; return false }) {
            Source(name: L("WORDaLIVE 자막"), kind: .captions, config: .captions(showSource: false, background: true, fontSize: 56, lines: 1))
        }
        let box = reuse(.captions, where: { config in if case let .captions(_, _, _, lines) = config { return lines >= 3 }; return false }) {
            Source(name: L("WORDaLIVE 자막 · 상자형"), kind: .captions, config: .captions(showSource: false, background: true, fontSize: 64, lines: 3))
        }
        var map = wordaliveSceneMap
        var made = 0
        for layout in Self.wordaliveLayouts where map[layout.id] == nil {
            var scene = ShowScene(name: layout.name)
            if let frame = layout.camera {
                var item = SceneItem(sourceID: camera, frame: frame)
                item.crop = Self.centerCrop(source: sourceSizes[camera] ?? CGSize(width: 1920, height: 1080), box: frame)
                scene.items.append(item)
            }
            if let frame = layout.slide { scene.items.append(SceneItem(sourceID: slide, frame: frame)) }
            scene.items.append(SceneItem(sourceID: layout.boxCaption ? box : band, frame: layout.caption))
            scene.items.append(SceneItem(sourceID: mic, frame: .zero))
            scenes.append(scene)
            map[layout.id] = scene.id
            made += 1
        }
        wordaliveSceneMap = map
        if made > 0, let first = map["split-left"] { selectedSceneID = first }
        return made
    }

    /// WORDaLIVE에서 배치를 바꾸면 진행 화면에서 그 장면을 바로 송출한다
    func followWordaliveLayout(_ id: String) {
        guard isInPerformanceMode, let sceneID = wordaliveSceneMap[id], programSceneID != sceneID else { return }
        goLive(sceneID)
    }
}
