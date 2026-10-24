// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit
import CoreGraphics

/// 화면 녹화 권한 (자료 창 캡처용).
/// macOS는 권한 창을 앱마다 한 번만 띄우고, 허용 후에는 앱을 다시 열어야 적용된다.
/// 그래서 ① 요청 → ② 안 뜨면 시스템 설정을 바로 연다 → ③ 다시 시작 버튼까지 한 흐름으로 안내한다.
@MainActor
@Observable
final class ScreenPermission {
    static let shared = ScreenPermission()

    private(set) var granted = CGPreflightScreenCaptureAccess()
    private(set) var requested = UserDefaults.standard.bool(forKey: "screenCapture.requested")

    func refresh() { granted = CGPreflightScreenCaptureAccess() }

    func request() {
        requested = true
        UserDefaults.standard.set(true, forKey: "screenCapture.requested")
        let ok = CGRequestScreenCaptureAccess()
        granted = ok || CGPreflightScreenCaptureAccess()
        // 이미 한 번 물어본 적이 있으면 macOS가 창을 다시 띄우지 않는다 → 설정 화면을 직접 연다
        if !granted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.granted else { return }
            self.openSettings()
        } }
    }

    func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// 허용한 권한은 앱을 다시 열어야 적용된다
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// 권한이 없을 때 어디서든 같은 모양으로 보여 주는 안내 (창 선택, 속성, 준비 화면)
struct ScreenPermissionNotice: View {
    @State private var permission = ScreenPermission.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("화면 녹화 권한이 필요합니다", systemImage: "rectangle.dashed.badge.record")
                .font(.uiHeadline)
            Text(permission.requested
                 ? L("시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 기록에서 Church OBS를 켠 뒤, 아래 ‘다시 시작’을 누르세요.")
                 : L("PPT·가사 프로그램 같은 자료 창을 장면에 넣으려면 macOS 화면 녹화 권한이 필요합니다."))
                .font(.uiCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if permission.requested {
                    Button("시스템 설정 열기") { permission.openSettings() }
                    Button("다시 시작") { permission.relaunch() }.churchProminentButton()
                } else {
                    Button("권한 요청") { permission.request() }.churchProminentButton()
                }
            }
            .controlSize(compact ? .regular : .large)
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: ChurchShape.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.floating, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        .onAppear { permission.refresh() }
    }
}
