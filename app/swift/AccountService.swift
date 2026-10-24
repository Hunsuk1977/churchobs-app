// AccountService.swift
// Church OBS — 계정 로그인, 요금제(무료/Pro), 예배 시나리오 클라우드 저장, 기본 세팅 동기화
//
// 서버: Cloudflare Worker "church-obs-api" + D1 (server/cloudflare)
//   - 로그인: Google 또는 이메일 6자리 코드 (비밀번호 없음)
//   - 세션 토큰은 키체인에 보관 (90일, 쓰면 연장)
//   - 요금제: /me (Stripe 웹훅만 서버에서 바꿈)
//   - 시나리오: 무료 1개 (서버가 막음) + 이 Mac에 사본 (인터넷이 끊겨도 예배 진행)
//
// 안정성 원칙
//   - 방송·녹화 중에는 요금제가 내려가지 않는다 (예배 도중 워터마크가 갑자기 생기지 않게)
//   - 인터넷이 끊겨도 마지막으로 확인한 Pro 상태를 14일간 유지한다

import Foundation
import Security
import Observation
import AppKit

// MARK: - 서버 주소

enum CloudConfig {
    /// Worker 배포 후 나오는 주소. 예: "https://church-obs-api.xxxx.workers.dev"
    static let apiURL = "https://church-obs-api.baehs.workers.dev"
    static var isConfigured: Bool { !apiURL.isEmpty }
    static let appVersion = "0.8.0"
    static let urlScheme = "churchobs"
}

// MARK: - 요금제

enum PlanTier: String, Codable { case free, pro }

struct PlanFeatures: Equatable {
    let tier: PlanTier
    var isPro: Bool { tier == .pro }
    /// 송출 화면 오른쪽 아래 "Church OBS · 무료 버전"
    var watermark: Bool { !isPro }
    /// 얼굴 자연 보정
    var beauty: Bool { isPro }
    var maxScenarios: Int { isPro ? 500 : 1 }
    var maxCameras: Int { isPro ? 8 : 1 }
    static let free = PlanFeatures(tier: .free)
}

// MARK: - 데이터

struct CloudSession: Codable {
    var token: String
    var expiresAt: Date
    var userID: String
    var email: String
    var name: String?
    /// user · admin · owner (서버가 /me 로 알려 준다)
    var role: String? = nil
}

struct CachedEntitlement: Codable {
    var plan: PlanTier
    var status: String
    var periodEnd: Date?
    var checkedAt: Date
    var pro: Bool
}

struct ScenarioSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var updatedAt: Date
    var cachedOnly = false
}

/// 로그인하면 따라오는 기본 세팅
struct StudioDefaults: Codable, Equatable {
    var defaultTransition: SceneTransition?
    var beautyPreset: Int?
    var beauty: [String: Double]?
    var lookTone: Int?
    var lookToneAmount: Double?
    var lookBlur: Double?
    var countdownMinutes: Int?
    var countdownAuto: Bool?
    var lastScenarioID: UUID?
}

struct CloudError: LocalizedError {
    let message: String
    var isFreeLimit = false
    var unauthorized = false
    var errorDescription: String? { message }
}

// MARK: - 키체인 (로그인 정보)

enum CloudKeychain {
    private static let service = "app.churchobs.cloud"
    private static let account = "session"

    static func load() -> CloudSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: data)
    }

    static func save(_ session: CloudSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 계정 서비스

@MainActor
@Observable
final class AccountService {
    private(set) var session: CloudSession?
    private(set) var entitlement: CachedEntitlement?
    /// 지금 적용 중인 기능 (방송 중에는 내려가지 않음)
    private(set) var features: PlanFeatures = .free
    var scenarios: [ScenarioSummary] = []
    var busy = false
    var message = ""
    var offline = false
    /// 이메일 코드를 보낸 주소 (코드 입력 단계)
    var codeSentTo: String?
    /// 브라우저에서 Google 로그인을 기다리는 중
    var googleWaiting = false
    /// 지금 편집 중인 시나리오 (덮어쓰기 저장 대상)
    var currentScenarioID: UUID? {
        didSet { UserDefaults.standard.set(currentScenarioID?.uuidString, forKey: "cloud.currentScenario") }
    }
    var currentScenarioName: String? {
        didSet { UserDefaults.standard.set(currentScenarioName, forKey: "cloud.currentScenarioName") }
    }

    @ObservationIgnored private let networkEnabled: Bool
    @ObservationIgnored private var pendingNonce: String?
    @ObservationIgnored private var lastPushedDefaults: StudioDefaults?
    @ObservationIgnored private var pendingDefaults: StudioDefaults?
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    var signedIn: Bool { session != nil }
    var email: String? { session?.email }

    private static let graceDays: Double = 14
    private let cacheFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChurchOBS/scenarios", isDirectory: true)

    init(networkEnabled: Bool = true) {
        self.networkEnabled = networkEnabled && CloudConfig.isConfigured
        if networkEnabled {
            session = CloudKeychain.load()
            if session.map({ $0.expiresAt < Date() }) ?? false { session = nil; CloudKeychain.clear() }
            if let data = UserDefaults.standard.data(forKey: "cloud.entitlement") {
                entitlement = try? JSONDecoder().decode(CachedEntitlement.self, from: data)
            }
            currentScenarioID = UserDefaults.standard.string(forKey: "cloud.currentScenario").flatMap(UUID.init(uuidString:))
            currentScenarioName = UserDefaults.standard.string(forKey: "cloud.currentScenarioName")
        }
        features = Self.evaluate(entitlement, signedIn: session != nil)
        scenarios = cachedSummaries()
        AccountService.current = self
    }

    // MARK: 요금제 계산

    /// 서버를 연결하기 전(개발 모드)에는 Pro로 동작. 메뉴의 "무료 요금제 미리 보기"로 무료 제한을 확인할 수 있다
    static var developmentMode: Bool { !CloudConfig.isConfigured }
    var simulateFree: Bool {
        get { UserDefaults.standard.bool(forKey: "cloud.simulateFree") }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.simulateFree"); reevaluate(allowDowngrade: true) }
    }

    private static func evaluate(_ e: CachedEntitlement?, signedIn: Bool) -> PlanFeatures {
        if developmentMode { return UserDefaults.standard.bool(forKey: "cloud.simulateFree") ? .free : PlanFeatures(tier: .pro) }
        guard signedIn, let e, e.pro else { return .free }
        // 인터넷이 끊겨도 마지막 확인 후 14일은 Pro 유지
        guard Date().timeIntervalSince(e.checkedAt) < graceDays * 86_400 else { return .free }
        return PlanFeatures(tier: .pro)
    }

    /// 방송·녹화 중이면 Pro → 무료로 내리는 것만 미룬다 (올라가는 건 바로)
    func reevaluate(allowDowngrade: Bool) {
        let next = Self.evaluate(entitlement, signedIn: signedIn)
        if next.isPro || allowDowngrade { if next != features { features = next } }
    }

    // MARK: 시작

    func bootstrap(allowDowngrade: Bool) async {
        guard networkEnabled, signedIn else { reevaluate(allowDowngrade: allowDowngrade); return }
        await refreshEntitlement(allowDowngrade: allowDowngrade)
        await refreshScenarios()
    }

    // MARK: 이메일 코드 로그인

    func requestEmailCode(_ email: String) async {
        guard ensureConfigured() else { return }
        let clean = email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true; defer { busy = false }
        do {
            try await send("auth/email/start", method: "POST", json: ["email": clean], auth: false)
            codeSentTo = clean
            message = "\(clean)로 6자리 코드를 보냈습니다. 메일함(스팸함 포함)을 확인하세요."
        } catch { message = error.localizedDescription }
    }

    func verifyEmailCode(_ code: String) async -> Bool {
        guard ensureConfigured(), let email = codeSentTo else { return false }
        busy = true; defer { busy = false }
        do {
            let data = try await send("auth/email/verify", method: "POST", json: ["email": email, "code": code], auth: false)
            try await adopt(data)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: Google 로그인 (브라우저 → churchobs://auth 로 돌아옴)

    func beginGoogleLogin() {
        guard ensureConfigured() else { return }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        pendingNonce = nonce
        guard let url = URL(string: "\(CloudConfig.apiURL)/auth/google/start?nonce=\(nonce)") else { return }
        googleWaiting = true
        message = L("브라우저에서 Google 로그인을 마치면 자동으로 돌아옵니다.")
        NSWorkspace.shared.open(url)
    }

    func cancelGoogleLogin() {
        googleWaiting = false; pendingNonce = nil; message = ""
    }

    /// churchobs://auth?code=…&nonce=…  /  churchobs://billing
    func handleOpenURL(_ url: URL) async {
        guard url.scheme == CloudConfig.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "auth":
            guard let code = value("code"), let nonce = value("nonce"), nonce == pendingNonce else {
                message = L("로그인 요청이 맞지 않습니다. 앱에서 다시 시도하세요.")
                googleWaiting = false
                return
            }
            pendingNonce = nil
            busy = true; defer { busy = false; googleWaiting = false }
            do {
                let data = try await send("auth/exchange", method: "POST", json: ["code": code, "nonce": nonce], auth: false)
                try await adopt(data)
            } catch { message = error.localizedDescription }
        case "billing":
            await refreshEntitlement(allowDowngrade: true)
        default:
            break
        }
    }

    // MARK: 세션

    private func adopt(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let token = object["token"] as? String, let user = object["user"] as? [String: Any],
              let id = user["id"] as? String, let email = user["email"] as? String else {
            throw CloudError(message: L("로그인 응답이 올바르지 않습니다."))
        }
        let expires = (object["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(90 * 86_400).timeIntervalSince1970
        let next = CloudSession(token: token, expiresAt: Date(timeIntervalSince1970: expires), userID: id, email: email,
                                name: user["name"] as? String)
        session = next
        CloudKeychain.save(next)
        codeSentTo = nil
        message = ""
        await refreshEntitlement(allowDowngrade: true)
        await refreshScenarios()
    }

    func signOut() async {
        if networkEnabled, session != nil { _ = try? await send("auth/logout", method: "POST", json: [String: Any]()) }
        dropSession()
        message = L("로그아웃했습니다.")
    }

    private func dropSession() {
        session = nil
        CloudKeychain.clear()
        entitlement = nil
        UserDefaults.standard.removeObject(forKey: "cloud.entitlement")
        currentScenarioID = nil; currentScenarioName = nil
        scenarios = cachedSummaries()
        reevaluate(allowDowngrade: true)
    }

    // MARK: 요금제

    func refreshEntitlement(allowDowngrade: Bool) async {
        guard networkEnabled, signedIn else { reevaluate(allowDowngrade: allowDowngrade); return }
        do {
            let data = try await send("me", method: "GET", json: nil)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let plan = object["plan"] as? [String: Any] ?? [:]
            let end = (plan["current_period_end"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let cached = CachedEntitlement(plan: PlanTier(rawValue: plan["plan"] as? String ?? "free") ?? .free,
                                           status: plan["status"] as? String ?? "active",
                                           periodEnd: end, checkedAt: Date(),
                                           pro: plan["pro"] as? Bool ?? false)
            entitlement = cached
            if let data = try? JSONEncoder().encode(cached) { UserDefaults.standard.set(data, forKey: "cloud.entitlement") }
            if let role = (object["user"] as? [String: Any])?["role"] as? String, var s = session, s.role != role {
                s.role = role; session = s; CloudKeychain.save(s)
            }
            offline = false
        } catch let error as CloudError where error.unauthorized {
            message = error.message
        } catch {
            offline = true
        }
        reevaluate(allowDowngrade: allowDowngrade)
    }

    /// Stripe 결제 페이지 열기 (결제 후 앱으로 돌아오면 자동으로 다시 확인)
    func openCheckout(yearly: Bool) async {
        await openReturnedURL("billing/checkout", body: ["interval": yearly ? "year" : "month"])
    }

    func openBillingPortal() async {
        await openReturnedURL("billing/portal", body: [:])
    }

    private func openReturnedURL(_ path: String, body: [String: Any]) async {
        guard ensureConfigured(), signedIn else { message = L("먼저 로그인하세요."); return }
        busy = true; defer { busy = false }
        do {
            let data = try await send(path, method: "POST", json: body)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let text = object["url"] as? String, let url = URL(string: text) else { throw CloudError(message: L("결제 페이지 주소를 받지 못했습니다.")) }
            NSWorkspace.shared.open(url)
        } catch { message = error.localizedDescription }
    }

    // MARK: 예배 시나리오

    func refreshScenarios() async {
        guard networkEnabled, signedIn else { scenarios = cachedSummaries(); return }
        do {
            let data = try await send("scenarios", method: "GET", json: nil)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rows = object["scenarios"] as? [[String: Any]] ?? []
            scenarios = rows.compactMap { row in
                guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)), let name = row["name"] as? String else { return nil }
                let updated = (row["updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
                return ScenarioSummary(id: id, name: name, updatedAt: updated)
            }
            offline = false
        } catch {
            offline = true
            scenarios = cachedSummaries()
        }
    }

    var canAddScenario: Bool { scenarios.filter { !$0.cachedOnly }.count < features.maxScenarios }

    /// id가 있으면 덮어쓰기, 없으면 새로 저장. 성공하면 시나리오 id
    func saveScenario(name: String, snapshot: ShowStore.Snapshot, overwrite id: UUID?) async -> UUID? {
        guard ensureConfigured(), signedIn else { message = L("로그인하면 예배 시나리오를 저장할 수 있습니다."); return nil }
        busy = true; defer { busy = false }
        do {
            let encoded = try JSONEncoder().encode(snapshot)
            let dataObject = try JSONSerialization.jsonObject(with: encoded)
            let body: [String: Any] = ["name": name, "data": dataObject, "app_version": CloudConfig.appVersion]
            let savedID: UUID
            if let id {
                try await send("scenarios/\(id.uuidString.lowercased())", method: "PUT", json: body)
                savedID = id
            } else {
                let data = try await send("scenarios", method: "POST", json: body)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let new = (object["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw CloudError(message: L("저장 결과를 받지 못했습니다.")) }
                savedID = new
            }
            writeCache(id: savedID, name: name, snapshot: encoded)
            currentScenarioID = savedID; currentScenarioName = name
            message = "「\(name)」을(를) 저장했습니다."
            await refreshScenarios()
            return savedID
        } catch let error as CloudError {
            message = error.isFreeLimit ? L("무료 요금제는 예배 시나리오를 1개까지 저장할 수 있습니다. 기존 시나리오에 덮어쓰거나 Pro로 업그레이드하세요.") : error.message
            return nil
        } catch {
            message = "저장하지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    /// 클라우드에서 받고, 안 되면 이 Mac의 사본
    func loadScenario(_ id: UUID) async -> (name: String, snapshot: ShowStore.Snapshot)? {
        busy = true; defer { busy = false }
        if networkEnabled, signedIn {
            do {
                let data = try await send("scenarios/\(id.uuidString.lowercased())", method: "GET", json: nil)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if let name = object["name"] as? String, let payload = object["data"] {
                    let bytes = try JSONSerialization.data(withJSONObject: payload)
                    let snapshot = try JSONDecoder().decode(ShowStore.Snapshot.self, from: bytes)
                    writeCache(id: id, name: name, snapshot: bytes)
                    currentScenarioID = id; currentScenarioName = name
                    return (name, snapshot)
                }
            } catch {
                offline = true
            }
        }
        if let cached = readCache(id) {
            currentScenarioID = id; currentScenarioName = cached.name
            message = L("인터넷에 연결되지 않아 이 Mac에 저장된 사본을 열었습니다.")
            return cached
        }
        message = L("시나리오를 열지 못했습니다.")
        return nil
    }

    func renameScenario(_ id: UUID, to name: String) async {
        guard signedIn, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await send("scenarios/\(id.uuidString.lowercased())", method: "PUT", json: ["name": name])
            if currentScenarioID == id { currentScenarioName = name }
            await refreshScenarios()
        } catch { message = error.localizedDescription }
    }

    func deleteScenario(_ id: UUID) async {
        guard signedIn else { return }
        do {
            try await send("scenarios/\(id.uuidString.lowercased())", method: "DELETE", json: nil)
            try? FileManager.default.removeItem(at: cacheFolder.appendingPathComponent("\(id.uuidString).json"))
            if currentScenarioID == id { currentScenarioID = nil; currentScenarioName = nil }
            await refreshScenarios()
        } catch { message = error.localizedDescription }
    }

    // MARK: 기본 세팅

    func pullDefaults() async -> StudioDefaults? {
        guard networkEnabled, signedIn else { return nil }
        do {
            let data = try await send("settings", method: "GET", json: nil)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let payload = object["data"] as? [String: Any], !payload.isEmpty else { return nil }
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            let defaults = try? JSONDecoder().decode(StudioDefaults.self, from: bytes)
            lastPushedDefaults = defaults
            return defaults
        } catch { return nil }
    }

    /// 바뀐 세팅을 3초 모아서 한 번에 올린다
    func defaultsChanged(_ defaults: StudioDefaults) {
        guard networkEnabled, signedIn, defaults != lastPushedDefaults, defaults != pendingDefaults else { return }
        pendingDefaults = defaults
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, let pending = self.pendingDefaults else { return }
            do {
                let encoded = try JSONEncoder().encode(pending)
                let object = try JSONSerialization.jsonObject(with: encoded)
                try await self.send("settings", method: "PUT", json: ["data": object] as [String: Any])
                self.lastPushedDefaults = pending
            } catch { self.offline = true }
            self.pendingDefaults = nil
        }
    }

    // MARK: 이 Mac의 사본

    private struct CacheFile: Codable { var name: String; var updatedAt: Date; var snapshot: Data }

    private func writeCache(id: UUID, name: String, snapshot: Data) {
        do {
            try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            let file = CacheFile(name: name, updatedAt: Date(), snapshot: snapshot)
            try JSONEncoder().encode(file).write(to: cacheFolder.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch { message = "이 Mac에 사본을 남기지 못했습니다: \(error.localizedDescription)" }
    }

    private func readCache(_ id: UUID) -> (name: String, snapshot: ShowStore.Snapshot)? {
        guard let data = try? Data(contentsOf: cacheFolder.appendingPathComponent("\(id.uuidString).json")),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              let snapshot = try? JSONDecoder().decode(ShowStore.Snapshot.self, from: file.snapshot) else { return nil }
        return (file.name, snapshot)
    }

    private func cachedSummaries() -> [ScenarioSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> ScenarioSummary? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }
            return ScenarioSummary(id: id, name: file.name, updatedAt: file.updatedAt, cachedOnly: true)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: HTTP

    private func ensureConfigured() -> Bool {
        guard CloudConfig.isConfigured else {
            message = L("아직 Church OBS 서버가 연결되지 않았습니다. (CloudConfig.apiURL에 서버 주소를 넣어야 합니다)")
            return false
        }
        return true
    }

    /// 관리자 여부 (서버 role)
    var isAdmin: Bool { ["admin", "owner"].contains(session?.role ?? "") }
    var isOwner: Bool { session?.role == "owner" }

    /// 지금 앱의 계정 (서버 경유 기능이 로그인 토큰을 쓰려고)
    static weak var current: AccountService?

    /// 로그인한 사용자의 서버 기능 호출 (예: "unsplash/search?q=…")
    func cloud(_ path: String, method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        let data = try await send(path, method: method, json: json)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// 관리자 화면용: 서버 관리자 주소 호출
    func admin(_ path: String, method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        let data = try await send("admin/\(path)", method: method, json: json)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func send(_ path: String, method: String, json: Any?, auth: Bool = true) async throws -> Data {
        guard let url = URL(string: "\(CloudConfig.apiURL)/\(path)") else { throw CloudError(message: "서버 주소가 잘못되었습니다.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ChurchOBS/\(CloudConfig.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if auth {
            guard let token = session?.token else { throw CloudError(message: L("로그인이 필요합니다."), unauthorized: true) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw CloudError(message: L("서버에 연결하지 못했습니다. 인터넷 연결을 확인하세요.")) }
        guard let http = response as? HTTPURLResponse else { throw CloudError(message: L("서버 응답이 올바르지 않습니다.")) }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let text = object["error"] as? String ?? "서버 오류 (\(http.statusCode))"
            if http.statusCode == 401, auth {
                // 서버에서 세션이 끝났다 → 이 Mac에서도 로그아웃 (요금제는 방송 중이면 내려가지 않음)
                dropSession()
                throw CloudError(message: L("로그인이 만료되었습니다. 다시 로그인하세요."), unauthorized: true)
            }
            throw CloudError(message: text, isFreeLimit: object["code"] as? String == "FREE_LIMIT")
        }
        return data
    }
}
