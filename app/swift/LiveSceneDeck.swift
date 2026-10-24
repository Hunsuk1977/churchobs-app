// LiveSceneDeck.swift
// churchobs — "3 진행" 단계 하단: 장면 버튼 + 전환 효과
// 장면 편집에서 만든 순서·이름이 그대로 버튼이 된다. ⌘1–9 로 바로 전환, Space = 다음 장면.

import SwiftUI
import AppKit

struct LiveSceneDeck: View {
    @Bindable var store: ShowStore
    /// 좁은 곳: 장면을 한 줄씩 작은 목록으로
    var compact = false
    @State private var wordalive = WordaliveStudioHost.shared
    @State private var dropTarget: ShowScene.ID?
    var onEditScenes: () -> Void = {}

    var body: some View {
        Group {
            if store.scenes.isEmpty { emptyState }
            else if compact { compactBody } else { fullBody }
        }
        // 숨은 단축키: Space = 다음 장면
        .background {
            // WORDaLIVE 스튜디오에 글을 쓰는 중에는 Space를 그쪽에 양보한다
            Button("미리보기를 송출로") { store.take() }
                .keyboardShortcut(wordalive.webFocused ? nil : KeyboardShortcut(.space, modifiers: []))
                .hidden()
        }
    }

    /// 장면이 하나도 없을 때: 무엇을 해야 하는지 한 줄 + 바로 가는 버튼
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("아직 장면이 없습니다").font(.uiHeadline)
            Text("장면 편집에서 카메라·자료를 넣은 장면을 만들면 여기에 버튼으로 나옵니다.")
                .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("장면 편집으로", action: onEditScenes).churchProminentButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("장면 · 클릭: 미리보기 · 더블클릭: 송출 · ⌥클릭: 출력 창").font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("편집 →", action: onEditScenes).buttonStyle(.link).font(.uiCaption)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Array(store.scenes.enumerated()), id: \.element.id) { index, scene in
                        SceneButton(store: store, scene: scene, index: index, compact: true)
                            .sceneReorderable(scene, store: store, dropTarget: $dropTarget)
                    }
                }
            }
            .scrollIndicators(.automatic)
            CompactTransitionControl(transition: $store.defaultTransition)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("장면 · 클릭: 미리보기 · 더블클릭: 바로 송출 · ⌥클릭: 출력 창 · 끌어서 순서 변경 · Space: 전환 · ⌘1–\(min(store.scenes.count, 9))")
                    .font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("장면 편집 →", action: onEditScenes).buttonStyle(.link).font(.uiCaption)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: max(min(store.scenes.count, 6), 1)),
                      spacing: 12) {
                ForEach(Array(store.scenes.enumerated()), id: \.element.id) { index, scene in
                    SceneButton(store: store, scene: scene, index: index)
                        .sceneReorderable(scene, store: store, dropTarget: $dropTarget)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                TransitionControl(transition: $store.defaultTransition)
            }
        }
    }
}

/// 좁은 곳용 전환 선택 (한 줄)
private struct CompactTransitionControl: View {
    @Binding var transition: SceneTransition
    var body: some View {
        HStack(spacing: 8) {
            Text("전환").font(.uiCaption).foregroundStyle(.secondary)
            Picker("전환 효과", selection: $transition.style) {
                ForEach(SceneTransition.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("전환 시간", selection: $transition.duration) {
                ForEach(SceneTransition.durations, id: \.self) { Text("\($0.formatted())초").tag($0) }
            }
            .labelsHidden().fixedSize()
            .disabled(transition.style == .cut)
        }
    }
}

private struct SceneButton: View {
    @Bindable var store: ShowStore
    let scene: ShowScene
    let index: Int
    var compact = false

    private var isLive: Bool { store.programSceneID == scene.id }
    private var isNext: Bool { store.previewSceneID == scene.id && !isLive }
    /// 출력 창(프로젝터)에 이 장면이 나가는가: 고정 장면이거나, "송출 그대로"일 때 송출 중인 장면
    private var onOutput: Bool { store.projectorOpen && (store.projectorSceneID == scene.id || (store.projectorSceneID == nil && isLive)) }
    /// 송출과 다른 장면을 출력 창에 고정해 둔 경우
    private var outputOnly: Bool { onOutput && !isLive }
    private static let cueColor = Color(red: 0.20, green: 0.78, blue: 0.35)
    private static let outputColor = ChurchBrand.blue

    var body: some View {
        let button = Button {
            // ⌥클릭: 출력 창에 띄우기 (송출·미리보기는 그대로)
            if NSEvent.modifierFlags.contains(.option) { store.setProjectorScene(scene.id) } else { store.cue(scene.id) }
        } label: {
            if compact { compactLabel } else { fullLabel }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !NSEvent.modifierFlags.contains(.option) { store.goLive(scene.id) } })
        .help("클릭: 미리보기에 올리기 · 더블클릭: 바로 송출 · ⌥클릭: 출력 창에 띄우기")
        .accessibilityLabel("\(scene.name) 장면을 미리보기에 올리기")
        .contextMenu {
            Button("미리보기에 올리기") { store.cue(scene.id) }
            Button("바로 송출") { store.goLive(scene.id) }
            Divider()
            Button("출력 창에 띄우기  ⌥클릭") { store.setProjectorScene(scene.id) }.disabled(store.projectorSceneID == scene.id)
            if store.projectorSceneID != nil {
                Button("출력 창: 송출 화면 그대로") { store.setProjectorScene(nil) }
            }
        }

        if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }

    private var tint: Color { isLive ? .red : isNext ? Self.cueColor : outputOnly ? Self.outputColor : Color.secondary.opacity(0.2) }

    /// "현재 화면 · 출력 창"처럼 붙이는 파란 꼬리표
    private var outputSuffix: Text {
        onOutput ? Text("  ·  ") + Text(Image(systemName: "tv.fill")).foregroundStyle(Self.outputColor) + Text(" " + L("출력 창")).foregroundStyle(Self.outputColor) : Text("")
    }

    /// 작은 칸: 썸네일 + 이름 + 상태 한 줄
    private var compactLabel: some View {
        HStack(spacing: 8) {
            SceneThumbnail(scene: scene, store: store)
                .frame(width: 52, height: 29)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(scene.name).font(.uiCaption.weight(isLive ? .bold : .semibold)).lineLimit(1)
                Group {
                    if isLive { (Text(store.broadcasting ? "ON AIR" : L("현재 화면")).foregroundStyle(.red) + outputSuffix) }
                    else if isNext { (Text("미리보기").foregroundStyle(Self.cueColor) + outputSuffix) }
                    else if outputOnly { Label("출력 창", systemImage: "tv.fill").foregroundStyle(Self.outputColor) }
                    else if !store.mainMicOn(in: scene) { Label("마이크 꺼짐", systemImage: "mic.slash.fill").foregroundStyle(.orange) }
                    else if index < 9 { Text("⌘\(index + 1)").foregroundStyle(.tertiary) }
                    else { Text(" ") }
                }
                .font(.uiCaption2.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isLive ? Color.red.opacity(0.22) : isNext ? Self.cueColor.opacity(0.12) : outputOnly ? Self.outputColor.opacity(0.14) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: ChurchShape.button))
        .overlay(RoundedRectangle(cornerRadius: ChurchShape.button).strokeBorder(tint, lineWidth: isLive ? 2.5 : isNext || outputOnly ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: ChurchShape.button))
    }

    private var fullLabel: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SceneThumbnail(scene: scene, store: store)
                        .frame(width: 72, height: 40)
                    Spacer()
                    if isLive {
                        (Text(store.broadcasting ? "ON AIR" : L("현재 화면")).foregroundStyle(.red) + outputSuffix).font(.uiCaption2.weight(.heavy))
                    } else if isNext {
                        (Text("미리보기 · Space").foregroundStyle(Self.cueColor) + outputSuffix).font(.uiCaption2.weight(.semibold))
                    } else if outputOnly {
                        Label("출력 창", systemImage: "tv.fill").font(.uiCaption2.weight(.semibold)).foregroundStyle(Self.outputColor)
                    } else if index < 9 {
                        Text("⌘\(index + 1)").font(.uiCaption2).foregroundStyle(.tertiary)
                    }
                }
                Text(scene.name).font(.uiTitle3.weight(isLive ? .bold : .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(transitionLabel).font(.uiCaption2).foregroundStyle(.secondary)
                    if !store.mainMicOn(in: scene) {
                        Label("마이크 꺼짐", systemImage: "mic.slash.fill").font(.uiCaption2).foregroundStyle(.orange)
                            .help("이 장면에서는 강단 마이크 소리가 나가지 않습니다")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(isLive ? Color.red.opacity(0.22) : isNext ? Self.cueColor.opacity(0.12) : outputOnly ? Self.outputColor.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: ChurchShape.floating))
            .overlay(
                RoundedRectangle(cornerRadius: ChurchShape.floating)
                    .strokeBorder(tint, lineWidth: isLive ? 3 : isNext || outputOnly ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ChurchShape.floating))
    }

    private var transitionLabel: String {
        guard let t = scene.transitionIn else { return L("기본 전환") }
        return t.style == .cut ? "컷" : "\(t.style.title) \(t.duration.formatted())초"
    }
}

/// 컷 | 페이드 | 슬라이드  +  0.3 / 0.5 / 1초
struct TransitionControl: View {
    @Binding var transition: SceneTransition

    var body: some View {
        HStack(spacing: 10) {
            Text("전환").font(.uiCaption).foregroundStyle(.secondary)
            Picker("전환 효과", selection: $transition.style) {
                ForEach(SceneTransition.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Picker("전환 시간", selection: $transition.duration) {
                ForEach(SceneTransition.durations, id: \.self) { Text("\($0.formatted())초").tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)
            .disabled(transition.style == .cut)
        }
    }
}

