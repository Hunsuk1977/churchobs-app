// StudioMonitors.swift
// Church OBS — 진행 화면 스튜디오 모드: 왼쪽 미리보기(초록) | 가운데 손잡이·전환 | 오른쪽 송출(빨강)
//
// 가운데 손잡이를 좌우로 끌면 두 화면 크기가 바뀌고(더블클릭하면 반반), 가운데 → 버튼(또는 Space)은
// 미리보기 장면을 송출로 보낸다. 송출 화면은 언제나 빨간 테두리, 실제 방송 중에는 굵은 테두리·빛·LIVE 표시.

import SwiftUI
import AppKit

struct StudioMonitors: View {
    let preview: NSView
    let program: NSView?
    var previewName: String?
    var programName: String?
    var live: Bool
    var recording: Bool
    var connecting: Bool
    var canTake: Bool
    /// 좁은 곳(WORDaLIVE 스튜디오 옆): 송출 위 · 전환 버튼 · 미리보기 아래로 쌓는다
    var vertical = false
    var onTake: () -> Void

    @AppStorage("studio.split") private var split: Double = 0.5
    /// 끄는 동안의 목표 비율. 손을 놓을 때만 실제 화면 크기를 바꾼다 (GPU 화면 크기가 매 순간 바뀌면 떨린다)
    @State private var dragSplit: Double?
    private let gutter: CGFloat = 48

    static let previewTint = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let programTint = Color(red: 1.0, green: 0.23, blue: 0.19)

    var body: some View {
        if vertical { stacked } else { sideBySide }
    }

    private var stacked: some View {
        VStack(spacing: 10) {
            programMonitor.aspectRatio(16.0 / 9.0 * 0.86, contentMode: .fit)
            HStack(spacing: 10) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 3)
                Button(action: onTake) {
                    Label("송출로 전환", systemImage: "arrow.up")
                        .font(.uiCaption.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(canTake ? Self.programTint : Color.secondary.opacity(0.25), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canTake)
                .help("미리보기 장면을 송출로 전환 (Space)")
                Text("Space").font(.uiCaption2.weight(.semibold)).foregroundStyle(.secondary)
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 3)
            }
            previewMonitor.aspectRatio(16.0 / 9.0 * 0.86, contentMode: .fit)
        }
    }

    private var sideBySide: some View {
        GeometryReader { g in
            let avail = max(g.size.width - gutter, 2)
            let left = avail * split
            HStack(alignment: .center, spacing: 0) {
                previewMonitor.frame(width: left)
                centerHandle(avail: avail).frame(width: gutter)
                programMonitor.frame(width: avail - left)
            }
            .frame(width: g.size.width, height: g.size.height)
            .overlay(alignment: .topLeading) {
                if let d = dragSplit {
                    let x = avail * d + gutter / 2
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2, height: g.size.height)
                        Text("미리보기 \(Int((d * 100).rounded()))% · 송출 \(100 - Int((d * 100).rounded()))%")
                            .font(.uiCaption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .churchGlass()
                            .fixedSize()
                    }
                    .position(x: x, y: g.size.height / 2)
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named("studio"))
        }
    }

    // MARK: 왼쪽: 미리보기

    private var previewMonitor: some View {
        MonitorFrame(
            title: L("미리보기"),
            detail: previewName.map { "다음: \($0)" } ?? "다음 장면 없음",
            tint: Self.previewTint,
            borderWidth: 2,
            strong: false,
            glow: false,
            badge: nil,
            emptyMessage: previewName == nil ? L("아래 장면 버튼을 눌러 다음 장면을 고르세요") : nil
        ) { EngineSurface(preview: preview) }
    }

    // MARK: 오른쪽: 송출

    private var programMonitor: some View {
        let title = live ? L("방송 중") : recording ? L("녹화 중") : L("송출 화면")
        let badge: AnyView
        if live { badge = AnyView(LiveBadge(text: "LIVE")) }
        else if recording { badge = AnyView(LiveBadge(text: "REC")) }
        else if connecting { badge = AnyView(StatusChip(text: L("송출 연결 확인 중"), color: .orange)) }
        else { badge = AnyView(StatusChip(text: L("방송 시작 전 · 이 화면이 나갑니다"), color: Self.programTint)) }

        return MonitorFrame(
            title: title,
            detail: programName ?? L("아직 내보낸 장면 없음"),
            tint: Self.programTint,
            borderWidth: live || recording ? 5 : 2.5,
            strong: true,
            glow: live,
            badge: badge,
            emptyMessage: program == nil ? L("이 엔진 버전은 송출 화면 미리보기를 지원하지 않습니다") : nil
        ) {
            if let program { EngineSurface(preview: program) } else { Color.black }
        }
    }

    // MARK: 가운데: 크기 손잡이 + 전환 버튼

    private func centerHandle(avail: CGFloat) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            // 화면 크기 되돌리기 (반반). 이미 반반이면 흐리게
            Button { withAnimation(.easeOut(duration: 0.2)) { split = 0.5 } } label: {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .churchGlass(ChurchShape.button, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(abs(split - 0.5) < 0.01 ? Color.secondary.opacity(0.5) : Color.primary)
            .disabled(abs(split - 0.5) < 0.01)
            .help("미리보기·송출 화면 크기를 반반으로 되돌리기")
            .accessibilityLabel("화면 크기 반반으로 되돌리기")
            Text("반반").font(.uiCaption2.weight(.semibold)).foregroundStyle(.secondary)
            grip
            Button(action: onTake) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 38, height: 38)
                    .background(canTake ? Self.programTint : Color.secondary.opacity(0.25), in: Circle())
                    .foregroundStyle(.white)
                    .shadow(color: canTake ? Self.programTint.opacity(0.5) : .clear, radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(!canTake)
            .help("미리보기 장면을 송출로 전환 (Space)")
            .accessibilityLabel("미리보기 장면을 송출로 전환")
            Text("Space").font(.uiCaption2.weight(.semibold)).foregroundStyle(.secondary)
            grip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            // 움직이는 손잡이가 아니라 전체 화면 기준 좌표로 계산 (손잡이 기준이면 값이 흔들린다)
            DragGesture(minimumDistance: 2, coordinateSpace: .named("studio"))
                .onChanged { v in
                    dragSplit = min(max(Double((v.location.x - gutter / 2) / avail), 0.15), 0.85)
                }
                .onEnded { _ in
                    if let d = dragSplit { split = d }
                    dragSplit = nil
                }
        )
        .onTapGesture(count: 2) { split = 0.5 }
        .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
        .help("좌우로 끌어 화면 크기 조절 · 더블클릭하면 반반")
    }

    private var grip: some View {
        Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 5, height: 46)
    }
}

/// 화면 하나: 위쪽 제목줄 + 16:9 엔진 화면 + 색 테두리
private struct MonitorFrame<Content: View>: View {
    let title: String
    let detail: String
    let tint: Color
    let borderWidth: CGFloat
    let strong: Bool
    let glow: Bool
    let badge: AnyView?
    let emptyMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L(title))
                    .font(.uiCaption.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(strong ? tint : tint.opacity(0.18), in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
                    .foregroundStyle(strong ? Color.white : tint)
                Text(L(detail)).font(.uiCallout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let badge { badge }
            }
            content()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: ChurchShape.button))
                .overlay {
                    if let emptyMessage {
                        Text(emptyMessage).font(.uiCallout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: ChurchShape.button).strokeBorder(tint, lineWidth: borderWidth))
                .shadow(color: glow ? tint.opacity(0.65) : .clear, radius: glow ? 16 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }
}

/// 깜빡이는 빨간 LIVE / REC 표시
private struct LiveBadge: View {
    let text: String
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 7, height: 7).opacity(on ? 1 : 0.25)
            Text(L(text)).font(.uiCaption.weight(.heavy))
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(StudioMonitors.programTint, in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
        .foregroundStyle(.white)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
        .accessibilityLabel(text == "LIVE" ? L("방송 중") : L("녹화 중"))
    }
}

private struct StatusChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(L(text))
            .font(.uiCaption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous).strokeBorder(color.opacity(0.7)))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
