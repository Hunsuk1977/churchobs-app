// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

// 버튼·패널 모양 통일: 모두 둥근 모서리 상자. macOS 26 이상에서는 시스템 Liquid Glass를 쓰고,
// 그 이전 macOS에서는 같은 모양의 반투명 재질로 대신한다.

enum ChurchShape {
    static let button: CGFloat = 10
    static let panel: CGFloat = 14
    static let floating: CGFloat = 12
    static let badge: CGFloat = 6
}

struct ChurchGlassBackground: ViewModifier {
    var radius: CGFloat
    var interactive = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// 떠 있는 도구 막대·패널용 유리 배경 (둥근 상자)
    func churchGlass(_ radius: CGFloat = ChurchShape.floating, interactive: Bool = false) -> some View {
        modifier(ChurchGlassBackground(radius: radius, interactive: interactive))
    }

    /// 주요 동작 버튼 (브랜드 파랑). 한 화면·한 패널에 하나만 — 지금 해야 할 일
    @ViewBuilder func churchProminentButton(_ color: Color = ChurchBrand.blue) -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent).tint(color) } else { buttonStyle(.borderedProminent).tint(color) }
    }

    /// 일반 버튼 (색 없는 유리). 나머지 모든 버튼
    @ViewBuilder func churchButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass).tint(nil) } else { buttonStyle(.bordered).tint(nil) }
    }

    /// 앱 전체 기본값: 둥근 상자 버튼 + 유리 패널
    func churchChrome() -> some View {
        self
            .buttonBorderShape(.roundedRectangle(radius: ChurchShape.button))
            .groupBoxStyle(ChurchGroupBoxStyle())
            .churchButton()
    }
}

/// 브랜드 (Church OBS 로고 팩): Blue #326BEA · Charcoal #20242B · White
enum ChurchBrand {
    static let blue = Color(red: 0x32 / 255.0, green: 0x6B / 255.0, blue: 0xEA / 255.0)
    static let charcoal = Color(red: 0x20 / 255.0, green: 0x24 / 255.0, blue: 0x2B / 255.0)
}

/// 로고: 파란 심볼 + 흰 글자 (어두운 배경용). 그림 파일이 없으면 글자로 대신
struct ChurchLogo: View {
    var height: CGFloat = 26
    var body: some View {
        if let image = NSImage(named: "church-obs-wordmark") {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(height: height)
                .accessibilityLabel("Church OBS")
        } else {
            Text("Church OBS").font(.system(size: height * 0.9, weight: .bold))
        }
    }
}

/// 켜고 끄는 도구 단추 (룰러·가이드·스냅 등): 켜짐 = 옅은 파랑 바탕 + 파란 글자, 꺼짐 = 색 없음.
/// 꽉 찬 파랑은 '해야 할 일' 버튼에만 쓰기 위해, 상태 표시는 옅게 한다
struct ChurchToolToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.uiCallout.weight(configuration.isOn ? .semibold : .regular))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(configuration.isOn ? ChurchBrand.blue : Color.secondary)
                .background(configuration.isOn ? ChurchBrand.blue.opacity(0.16) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous)
                    .strokeBorder(configuration.isOn ? ChurchBrand.blue.opacity(0.45) : Color.secondary.opacity(0.2)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? L("켜짐") : L("꺼짐"))
    }
}

/// 작은 거름 단추 (전체·사진·영상 / 아이콘 추천어). 큰 탭과 구별되게 낮은 강조의 둥근 상자
struct FilterChip: View {
    let title: String
    var count: Int? = nil
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(L(title))
                if let count { Text("\(count)").foregroundStyle(selected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.7)) }
            }
            .font(.uiCaption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: ChurchShape.badge + 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// GroupBox를 유리 패널로
struct ChurchGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .churchGlass(ChurchShape.panel)
    }
}
