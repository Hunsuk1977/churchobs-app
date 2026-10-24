// AccountViews.swift
// Church OBS — 상단 계정 메뉴, 로그인 창, 예배 시나리오 보관함

import SwiftUI
import AppKit

// MARK: - 요금제 배지

struct PlanBadge: View {
    let features: PlanFeatures
    var body: some View {
        Text(features.isPro ? "PRO" : "무료")
            .font(.uiCaption2.weight(.heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(features.isPro ? Color(red: 0.95, green: 0.72, blue: 0.20) : Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
            .foregroundStyle(features.isPro ? Color.black : Color.secondary)
    }
}

// MARK: - 상단 계정 메뉴

struct AccountMenu: View {
    @Bindable var account: AccountService
    var onLogin: () -> Void
    var onScenarios: () -> Void
    @State private var showAdmin = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onScenarios) { Label("시나리오", systemImage: "square.stack.3d.up") }
                .help("예배 시나리오 저장·불러오기")
            Menu {
                if AccountService.developmentMode {
                    Text("개발 모드 · 서버 연결 전 (Pro 기능 모두 사용)")
                    Toggle("무료 요금제 미리 보기", isOn: Binding(get: { account.simulateFree }, set: { account.simulateFree = $0 }))
                    Divider()
                }
                if account.signedIn {
                    Text(account.email ?? "")
                    Text(account.features.isPro ? "Church OBS Pro" : "무료 요금제 · 워터마크, 시나리오 1개, 카메라 1대")
                    if account.offline { Text("오프라인 · 마지막으로 확인한 요금제 사용 중") }
                    Divider()
                    if account.features.isPro {
                        Button("구독 관리…") { Task { await account.openBillingPortal() } }
                    } else {
                        Button("Pro로 업그레이드 (월간)…") { Task { await account.openCheckout(yearly: false) } }
                        Button("Pro로 업그레이드 (연간)…") { Task { await account.openCheckout(yearly: true) } }
                    }
                    Button("요금제 다시 확인") { Task { await account.refreshEntitlement(allowDowngrade: true) } }
                    if account.isAdmin {
                        Divider()
                        Button("관리자…") { showAdmin = true }
                    }
                    Divider()
                    Button("로그아웃") { Task { await account.signOut() } }
                } else {
                    Button("로그인 · 가입…", action: onLogin)
                    Text("로그인하면 기본 세팅과 예배 시나리오가 저장됩니다")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: account.signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    if account.signedIn || AccountService.developmentMode { PlanBadge(features: account.features) }
                    if !account.signedIn { Text(AccountService.developmentMode ? "개발 모드" : "로그인") }
                }
            }
            .menuStyle(.borderlessButton)
            .sheet(isPresented: $showAdmin) { AdminSheet(account: account) }
            .fixedSize()
            LanguagePicker()
        }
    }
}

// MARK: - 로그인 창 (Google 또는 이메일 코드 — 비밀번호 없음)

struct LoginSheet: View {
    @Bindable var account: AccountService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChurchLogo(height: 32)
            LoginPanel(account: account)
            HStack {
                Spacer()
                Button("닫기") { account.cancelGoogleLogin(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .onChange(of: account.signedIn) { if account.signedIn { dismiss() } }
    }
}

/// 로그인 내용 (첫 화면과 로그인 창이 함께 씀): Google 또는 이메일 6자리 코드
struct LoginPanel: View {
    @Bindable var account: AccountService
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("로그인하면 기본 세팅과 예배 시나리오가 저장되고, 다른 Mac에서도 그대로 이어서 쓸 수 있습니다. 처음이면 자동으로 가입됩니다.")
                .font(.uiCallout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.googleWaiting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("브라우저에서 Google 로그인을 마치면 자동으로 돌아옵니다.").font(.uiCallout)
                    Spacer()
                    Button("취소") { account.cancelGoogleLogin() }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: ChurchShape.button))
            } else {
                Button { account.beginGoogleLogin() } label: {
                    HStack(spacing: 8) {
                        Text("G").font(.system(size: 16, weight: .heavy)).foregroundStyle(ChurchBrand.blue)
                        Text("Google로 계속").font(.uiBody.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .churchButton()
                .controlSize(.large)
                .disabled(account.busy)
            }

            HStack { Rectangle().frame(height: 1).foregroundStyle(.quaternary); Text("또는 이메일").font(.uiCaption).foregroundStyle(.secondary); Rectangle().frame(height: 1).foregroundStyle(.quaternary) }

            if let sentTo = account.codeSentTo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(sentTo)로 보낸 6자리 코드").font(.uiCaption).foregroundStyle(.secondary)
                    HStack {
                        TextField("123456", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.uiTitle3.monospacedDigit())
                            .frame(width: 140)
                            .onSubmit(verify)
                            .onChange(of: code) {
                                let digits = code.filter(\.isNumber)
                                if digits != code || digits.count > 6 { code = String(digits.prefix(6)) }
                                if code.count == 6 { verify() }
                            }
                        Button("로그인", action: verify).churchProminentButton().disabled(code.count != 6 || account.busy)
                        Spacer()
                    }
                    HStack(spacing: 14) {
                        Button("다른 이메일") { account.codeSentTo = nil; code = "" }.buttonStyle(.link)
                        Button("코드 다시 받기") { Task { await account.requestEmailCode(sentTo) } }.buttonStyle(.link).disabled(account.busy)
                    }
                    .font(.uiCaption)
                }
            } else {
                HStack {
                    TextField("이메일 주소", text: $email)
                        .textContentType(.username)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendCode)
                    Button("코드 받기", action: sendCode)
                        .disabled(!email.contains("@") || account.busy)
                }
            }

            if !account.message.isEmpty {
                Text(L(account.message)).font(.uiCaption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top) {
                Text("무료로 시작합니다 · 무료: 송출 워터마크, 자연 보정 없음, 시나리오 1개, 카메라 1대")
                    .font(.uiCaption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if account.busy { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { account.message = "" }
    }

    private func sendCode() {
        guard email.contains("@") else { return }
        Task { await account.requestEmailCode(email) }
    }

    private func verify() {
        guard code.count == 6, !account.busy else { return }
        Task { _ = await account.verifyEmailCode(code) }
    }
}

// MARK: - 언어 (한국어 · English)

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ko, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("시스템 설정 따르기")
        case .ko: "한국어"
        case .en: "English"
        }
    }
    static var current: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "") ?? .system }

    /// 앱 전체(메뉴·알림 포함)에 적용하려면 다시 시작해야 한다
    @MainActor static func apply(_ language: AppLanguage) {
        guard language != current else { return }
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: "app.language")
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
        defaults.synchronize()
        ScreenPermission.shared.relaunch()
    }
}

/// 언어 고르기 (첫 화면 오른쪽 위, 계정 메뉴)
struct LanguagePicker: View {
    @State private var pending: AppLanguage?
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    if lang != AppLanguage.current { pending = lang }
                } label: {
                    if lang == AppLanguage.current { Label(lang.title, systemImage: "checkmark") } else { Text(lang.title) }
                }
            }
        } label: {
            Label(AppLanguage.current == .system ? L("언어") : AppLanguage.current.title, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog(L("언어를 바꾸면 앱이 다시 시작됩니다."),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending.map { "\($0.title) · " + L("다시 시작") } ?? L("다시 시작")) { if let p = pending { AppLanguage.apply(p) } }
            Button("취소", role: .cancel) { pending = nil }
        }
    }
}

// MARK: - 첫 화면: 로그인 (+ 언어)

struct WelcomeGate: View {
    @Bindable var account: AccountService
    var onDeveloperContinue: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.065, blue: 0.08)
            RadialGradient(colors: [ChurchBrand.blue.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 620)
            VStack(spacing: 0) {
                HStack { Spacer(); LanguagePicker() }
                    .padding(.horizontal, 28).padding(.top, 22)
                Spacer(minLength: 24)
                VStack(spacing: 14) {
                    ChurchLogo(height: 58)
                    Text("예배 방송, 준비·장면·진행 세 단계면 끝.")
                        .font(.uiTitle3).foregroundStyle(.secondary)
                }
                .padding(.bottom, 30)

                LoginPanel(account: account)
                    .frame(width: 440)
                    .padding(28)
                    .churchGlass(ChurchShape.panel + 6)

                if AccountService.developmentMode {
                    VStack(spacing: 6) {
                        Text("서버 연결 전 · 개발 모드").font(.uiCaption.weight(.semibold)).foregroundStyle(.orange)
                        Button("로그인 없이 계속 (개발 모드)", action: onDeveloperContinue)
                        Text("서버 주소가 들어가면 이 버튼은 사라지고 로그인이 필요합니다.")
                            .font(.uiCaption2).foregroundStyle(.secondary)
                    }
                    .padding(.top, 22)
                }
                Spacer(minLength: 24)
                Text("인터넷이 끊겨도 마지막 로그인으로 14일 동안 계속 쓸 수 있습니다.")
                    .font(.uiCaption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 22)
            }
        }
    }
}

// MARK: - 예배 시나리오 보관함

struct ScenarioLibrarySheet: View {
    @Bindable var account: AccountService
    let currentTitle: String
    let editable: Bool
    var onSave: (_ name: String, _ overwrite: Bool) async -> Void
    var onOpen: (_ id: UUID) async -> Void
    var onLogin: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var confirmOpen: ScenarioSummary?
    @State private var confirmDelete: ScenarioSummary?
    @State private var renaming: ScenarioSummary?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("예배 시나리오").font(.uiTitle2.bold())
                if account.signedIn { PlanBadge(features: account.features) }
                Spacer()
                if account.busy { ProgressView().controlSize(.regular) }
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("장면 순서·소스·전환까지 예배 한 번의 구성 전체를 저장합니다. 이 Mac에도 사본이 남아 인터넷이 끊겨도 열 수 있습니다.")
                .font(.uiCallout).foregroundStyle(.secondary)

            if !account.signedIn {
                GroupBox {
                    HStack {
                        Text("로그인하면 예배 시나리오를 저장할 수 있습니다.")
                        Spacer()
                        Button("로그인 · 가입…") { dismiss(); onLogin() }.churchProminentButton()
                    }.padding(6)
                }
            } else {
                saveBox
            }

            if !account.message.isEmpty {
                Text(account.message).font(.uiCaption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(account.offline ? "저장된 시나리오 · 오프라인 (이 Mac의 사본)" : "저장된 시나리오")
                    .font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await account.refreshScenarios() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("새로고침").accessibilityLabel("새로고침")
            }

            List {
                if account.scenarios.isEmpty {
                    Text("아직 저장한 시나리오가 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(account.scenarios) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.id == account.currentScenarioID ? "checkmark.circle.fill" : "doc.richtext")
                            .foregroundStyle(s.id == account.currentScenarioID ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.uiBody.weight(.semibold))
                            Text((s.cachedOnly ? "이 Mac의 사본 · " : "") + s.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.uiCaption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("불러오기") { confirmOpen = s }.disabled(!editable || account.busy)
                        Menu {
                            Button("이름 바꾸기…") { renameText = s.name; renaming = s }
                            Button("삭제…", role: .destructive) { confirmDelete = s }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(s.cachedOnly || !account.signedIn)
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 220)
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .onAppear {
            account.message = ""
            newName = account.currentScenarioName ?? currentTitle
            Task { await account.refreshScenarios() }
        }
        .alert("이 시나리오를 불러올까요?", isPresented: Binding(get: { confirmOpen != nil }, set: { if !$0 { confirmOpen = nil } })) {
            Button("취소", role: .cancel) {}
            Button("불러오기") { if let s = confirmOpen { Task { await onOpen(s.id); dismiss() } } }
        } message: {
            Text("지금 장면 세트가 「\(confirmOpen?.name ?? "")」로 바뀝니다. 저장하지 않은 변경은 사라집니다.")
        }
        .alert("시나리오를 삭제할까요?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { if let s = confirmDelete { Task { await account.deleteScenario(s.id) } } }
        } message: {
            Text("「\(confirmDelete?.name ?? "")」을(를) 서버와 이 Mac에서 지웁니다. 되돌릴 수 없습니다.")
        }
        .sheet(item: $renaming) { s in
            VStack(alignment: .leading, spacing: 12) {
                Text("이름 바꾸기").font(.uiHeadline)
                TextField("시나리오 이름", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 320)
                HStack {
                    Spacer()
                    Button("취소") { renaming = nil }
                    Button("바꾸기") { Task { await account.renameScenario(s.id, to: renameText); renaming = nil } }
                        .churchProminentButton()
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private var saveBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("시나리오 이름 (예: 주일 2부 예배)", text: $newName).textFieldStyle(.roundedBorder)
                    if let current = account.currentScenarioName, account.currentScenarioID != nil {
                        Button("「\(current)」에 덮어쓰기") {
                            Task { await onSave(newName.isEmpty ? current : newName, true) }
                        }
                        .disabled(account.busy)
                    }
                    Button("새로 저장") { Task { await onSave(newName, false) } }
                        .churchProminentButton()
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || account.busy || !account.canAddScenario)
                }
                if !account.canAddScenario {
                    HStack {
                        Label("무료 요금제는 시나리오 1개까지입니다. 기존 시나리오에 덮어쓰거나 Pro로 업그레이드하세요.", systemImage: "lock.fill")
                            .font(.uiCaption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Pro 보기") { Task { await account.openCheckout(yearly: false) } }.controlSize(.regular)
                    }
                }
            }
            .padding(6)
        }
    }
}


// MARK: - 관리자

struct AdminUser: Identifiable {
    let id: String
    let email: String
    let name: String
    let role: String
    let pro: Bool
    let source: String          // stripe · admin · none
    let compUntil: Double?      // 0 = 무기한
    let compNote: String
    let lastSeen: Date?
    let created: Date
    let scenarios: Int

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, let email = o["email"] as? String else { return nil }
        self.id = id; self.email = email
        name = o["name"] as? String ?? ""
        role = o["role"] as? String ?? "user"
        pro = o["pro"] as? Bool ?? false
        source = o["source"] as? String ?? "none"
        compUntil = (o["comp_until"] as? NSNumber)?.doubleValue
        compNote = o["comp_note"] as? String ?? ""
        lastSeen = (o["last_seen"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        created = Date(timeIntervalSince1970: (o["created_at"] as? NSNumber)?.doubleValue ?? 0)
        scenarios = (o["scenarios"] as? NSNumber)?.intValue ?? 0
    }

    var planText: String {
        if !pro { return L("무료") }
        if source == "stripe" { return "Pro · " + L("구독") }
        if let until = compUntil, until > 0 { return "Pro · ~" + Self.day.string(from: Date(timeIntervalSince1970: until)) }
        return "Pro · " + L("무기한")
    }
    static let day: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
}

/// 관리자 화면: 사용자 찾기, Pro 직접 주기, 관리자 지정, 강제 로그아웃
struct AdminSheet: View {
    @Bindable var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var users: [AdminUser] = []
    @State private var stats: [String: Int] = [:]
    @State private var busy = false
    @State private var message = ""
    @State private var noteDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("관리자").font(.uiTitle2.bold())
                Text(account.isOwner ? L("최상위 관리자") : L("관리자")).font(.uiCaption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Spacer()
                Button("닫기") { dismiss() }
            }
            HStack(spacing: 14) {
                stat("사용자", stats["users"])
                stat("Pro 구독", stats["pro_stripe"])
                stat("Pro 직접 부여", stats["pro_comp"])
                stat("최근 7일 사용", stats["active_week"])
                stat("관리자", stats["admins"])
            }
            HStack(spacing: 8) {
                TextField("이메일이나 이름으로 찾기", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await load() } }
                Button("찾기") { Task { await load() } }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            if !message.isEmpty { Text(message).font(.uiCaption).foregroundStyle(.orange) }
            Table(users) {
                TableColumn(L("사용자")) { u in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(u.email).font(.uiBody.weight(.semibold))
                            if u.role != "user" {
                                Text(u.role == "owner" ? L("최상위") : L("관리자")).font(.uiCaption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: ChurchShape.badge))
                            }
                        }
                        Text(u.name).font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
                TableColumn(L("요금제")) { u in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.planText).font(.uiCaption.weight(.semibold)).foregroundStyle(u.pro ? ChurchStatus.ok : .secondary)
                        if !u.compNote.isEmpty { Text(u.compNote).font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }.width(min: 140, ideal: 170)
                TableColumn(L("마지막 사용")) { u in
                    Text(u.lastSeen.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? L("없음"))
                        .font(.uiCaption).foregroundStyle(.secondary)
                }.width(min: 90, ideal: 110)
                TableColumn(L("가입")) { u in Text(AdminUser.day.string(from: u.created)).font(.uiCaption).foregroundStyle(.secondary) }.width(min: 90, ideal: 100)
                TableColumn("") { u in actions(u) }.width(60)
            }
            .frame(minHeight: 320)
            Text("Pro 직접 부여는 결제 없이 Pro 기능을 열어 줍니다. 구독 결제가 있으면 결제가 우선이고, 모든 작업은 서버 기록에 남습니다.")
                .font(.uiCaption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 860, height: 600)
        .disabled(busy)
        .task { await load() }
    }

    private static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(String.init) ?? "–").font(.uiTitle3.weight(.bold).monospacedDigit())
            Text(L(title)).font(.uiCaption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
    }

    private func actions(_ u: AdminUser) -> some View {
        Menu {
            Section(L("Pro 직접 부여")) {
                Button("1개월") { Task { await comp(u, "months", 1) } }
                Button("6개월") { Task { await comp(u, "months", 6) } }
                Button("1년") { Task { await comp(u, "months", 12) } }
                Button("무기한") { Task { await comp(u, "forever") } }
                if u.compUntil != nil { Button("직접 부여 해제", role: .destructive) { Task { await comp(u, "none") } } }
            }
            if account.isOwner, u.role != "owner" {
                Section(L("권한")) {
                    if u.role == "admin" { Button("관리자 해제") { Task { await role(u, "user") } } }
                    else { Button("관리자로 지정") { Task { await role(u, "admin") } } }
                }
            }
            Section {
                Button("모든 기기에서 로그아웃", role: .destructive) { Task { await logout(u) } }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func load() async {
        busy = true; defer { busy = false }
        do {
            async let s = account.admin("stats")
            async let list = account.admin("users?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=200")
            let (statsResult, listResult) = try await (s, list)
            stats = statsResult.compactMapValues { ($0 as? NSNumber)?.intValue }
            users = (listResult["users"] as? [[String: Any]] ?? []).compactMap(AdminUser.init)
            message = ""
        } catch {
            message = (error as? CloudError)?.message ?? error.localizedDescription
        }
    }

    private func comp(_ u: AdminUser, _ mode: String, _ months: Int = 0) async {
        var body: [String: Any] = ["mode": mode]
        if mode == "months" { body["months"] = months }
        await run { _ = try await account.admin("users/\(u.id)/comp", method: "POST", json: body) }
    }
    private func role(_ u: AdminUser, _ role: String) async {
        await run { _ = try await account.admin("users/\(u.id)/role", method: "POST", json: ["role": role]) }
    }
    private func logout(_ u: AdminUser) async {
        await run { _ = try await account.admin("users/\(u.id)/logout", method: "POST") }
    }
    private func run(_ work: () async throws -> Void) async {
        busy = true
        do { try await work(); busy = false; await load(); await account.refreshEntitlement(allowDowngrade: false) }
        catch { busy = false; message = (error as? CloudError)?.message ?? error.localizedDescription }
    }
}
