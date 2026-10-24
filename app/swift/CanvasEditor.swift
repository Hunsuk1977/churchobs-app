// CanvasEditor.swift
// churchobs — 장면 캔버스 편집기 (Canva식 선택·변형, 스마트 가이드, 크롭, 룰러)
//
// 조작 요약
//   클릭 선택 · 드래그 이동 (⇧ 수평/수직 고정, ⌘ 스냅 끄기, ⌥ 화면 가장자리까지 거리 표시)
//   모서리 핸들: 비율 유지 크기 조절 (⇧ 자유 비율)
//   옆 핸들: 카메라·창·사진은 자르기(Canva 사진과 동일), 문구는 늘리기
//   ⌥ + 아무 핸들: 자르기 (OBS의 Alt 드래그와 동일)
//   더블클릭 / ⏎ / 속성 패널 "자르기": 자르기 모드 — 바깥 영역이 어둡게 보이고, 안을 끌면 화면이 움직임
//   화살표 1px · ⇧화살표 10px · ⌫ 삭제 · ⎋ 선택 해제 · ⇧R 룰러
//   룰러에서 캔버스로 끌어 가이드 생성, 가이드를 룰러 밖으로 끌거나 더블클릭하면 삭제
//
// 성능: 드래그 중에는 저장소(ShowStore)를 건드리지 않는다. 이 화면의 로컬 상태만 바뀌고,
//       엔진에는 updateLayout(빠른 경로)으로 해당 레이어 위치만 보낸다. 손을 떼면 한 번 저장한다.

import SwiftUI
import AppKit

// MARK: - 스타일

enum CanvasStyle {
    static let selection = Color(red: 0.55, green: 0.24, blue: 1.0)     // 선택 테두리 (보라)
    static let smartGuide = Color(red: 1.0, green: 0.20, blue: 0.62)    // 스마트 가이드·간격 (분홍)
    static let userGuide = Color(red: 0.0, green: 0.78, blue: 0.82)     // 룰러 가이드 (청록)
    static let rulerBackground = Color(white: 0.12)
    static let rulerTick = Color(white: 0.55)
    static let rulerText = Color(white: 0.72)
    static let rulerSize: CGFloat = 20
    static let snapDistance: CGFloat = 6        // 화면 포인트
}

// MARK: - 핸들

enum CanvasHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var isVerticalSide: Bool { self == .left || self == .right }

    func point(in r: CGRect) -> CGPoint {
        let x: CGFloat = movesLeft ? r.minX : movesRight ? r.maxX : r.midX
        let y: CGFloat = movesTop ? r.minY : movesBottom ? r.maxY : r.midY
        return CGPoint(x: x, y: y)
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }
}

// MARK: - 스마트 가이드 계산 (순수 함수)

struct GuideLine: Hashable {
    var axis: CanvasAxis      // .vertical = x 위치의 세로선
    var position: CGFloat
    var from: CGFloat
    var to: CGFloat
}

struct GapMark: Hashable {
    var alongX: Bool          // true = 가로 방향 거리
    var start: CGFloat
    var end: CGFloat
    var cross: CGFloat
    var equal: Bool
    var pixels: Int { Int(((end - start) * (alongX ? OutputCanvas.width : OutputCanvas.height)).rounded()) }
}

enum SmartGuides {
    struct Result {
        var rect: CGRect
        var lines: [GuideLine] = []
        var gaps: [GapMark] = []
    }

    static func targets(_ others: [CGRect], _ guides: [CanvasGuide], _ axis: CanvasAxis) -> [CGFloat] {
        var t: [CGFloat] = [0, 0.5, 1]
        for o in others { t += axis == .vertical ? [o.minX, o.midX, o.maxX] : [o.minY, o.midY, o.maxY] }
        t += guides.filter { $0.axis == axis }.map(\.position)
        return t
    }

    static func bestDelta(_ points: [CGFloat], _ targets: [CGFloat], threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for p in points {
            for t in targets {
                let d = t - p
                if abs(d) <= threshold, abs(d) < abs(best ?? .infinity) { best = d }
            }
        }
        return best
    }

    /// 양옆 이웃 사이 한가운데(같은 간격)로 가려면 얼마나 움직여야 하는가
    static func equalSpacingDelta(_ r: CGRect, _ others: [CGRect], alongX: Bool) -> CGFloat? {
        let overlapping = others.filter { alongX ? ($0.maxY > r.minY && $0.minY < r.maxY) : ($0.maxX > r.minX && $0.minX < r.maxX) }
        let lo = overlapping.filter { alongX ? $0.maxX <= r.midX : $0.maxY <= r.midY }
            .max { alongX ? $0.maxX < $1.maxX : $0.maxY < $1.maxY }
        let hi = overlapping.filter { alongX ? $0.minX >= r.midX : $0.minY >= r.midY }
            .min { alongX ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard let lo, let hi else { return nil }
        let a = alongX ? lo.maxX : lo.maxY, b = alongX ? hi.minX : hi.minY
        let size = alongX ? r.width : r.height
        let target = (a + b - size) / 2
        guard target >= a, target + size <= b else { return nil }
        return target - (alongX ? r.minX : r.minY)
    }

    static func snapMove(_ start: CGRect, others: [CGRect], guides: [CanvasGuide],
                         threshold: CGSize, snap: Bool, edgeGaps: Bool) -> Result {
        var r = start
        if snap {
            var dx = bestDelta([r.minX, r.midX, r.maxX], targets(others, guides, .vertical), threshold: threshold.width)
            if let e = equalSpacingDelta(r, others, alongX: true), abs(e) <= threshold.width, abs(e) < abs(dx ?? .infinity) { dx = e }
            var dy = bestDelta([r.minY, r.midY, r.maxY], targets(others, guides, .horizontal), threshold: threshold.height)
            if let e = equalSpacingDelta(r, others, alongX: false), abs(e) <= threshold.height, abs(e) < abs(dy ?? .infinity) { dy = e }
            r.origin.x += dx ?? 0
            r.origin.y += dy ?? 0
        }
        r = keepInside(r)
        return Result(rect: r, lines: lines(for: r, others, guides), gaps: gaps(for: r, others, edges: edgeGaps))
    }

    /// 캔버스 밖으로 나가지 않게 (엔진도 같은 규칙으로 자른다)
    static func keepInside(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(max(r.width, 0.02), 1)
        r.size.height = min(max(r.height, 0.02), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// 지금 정확히 맞닿아 있는 정렬선들
    static func lines(for r: CGRect, _ others: [CGRect], _ guides: [CanvasGuide]) -> [GuideLine] {
        let eps: CGFloat = 0.0008
        var out: [GuideLine] = []
        func add(_ axis: CanvasAxis, _ p: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            if let i = out.firstIndex(where: { $0.axis == axis && abs($0.position - p) < eps }) {
                out[i].from = min(out[i].from, from); out[i].to = max(out[i].to, to)
            } else { out.append(GuideLine(axis: axis, position: p, from: from, to: to)) }
        }
        for p in [r.minX, r.midX, r.maxX] {
            if [0, 0.5, 1].contains(where: { abs($0 - p) < eps }) { add(.vertical, p, 0, 1) }
            for o in others where [o.minX, o.midX, o.maxX].contains(where: { abs($0 - p) < eps }) {
                add(.vertical, p, min(r.minY, o.minY), max(r.maxY, o.maxY))
            }
            for g in guides where g.axis == .vertical && abs(g.position - p) < eps { add(.vertical, p, 0, 1) }
        }
        for p in [r.minY, r.midY, r.maxY] {
            if [0, 0.5, 1].contains(where: { abs($0 - p) < eps }) { add(.horizontal, p, 0, 1) }
            for o in others where [o.minY, o.midY, o.maxY].contains(where: { abs($0 - p) < eps }) {
                add(.horizontal, p, min(r.minX, o.minX), max(r.maxX, o.maxX))
            }
            for g in guides where g.axis == .horizontal && abs(g.position - p) < eps { add(.horizontal, p, 0, 1) }
        }
        return out
    }

    /// 가장 가까운 이웃까지의 거리 (⌥: 이웃이 없으면 화면 가장자리까지)
    static func gaps(for r: CGRect, _ others: [CGRect], edges: Bool) -> [GapMark] {
        var out: [GapMark] = []
        let rowMates = others.filter { $0.maxY > r.minY && $0.minY < r.maxY }
        let colMates = others.filter { $0.maxX > r.minX && $0.minX < r.maxX }
        func cross(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { (max(a0, b0) + min(a1, b1)) / 2 }

        var left: GapMark?, right: GapMark?, top: GapMark?, bottom: GapMark?
        if let l = rowMates.filter({ $0.maxX <= r.minX + 0.0005 }).max(by: { $0.maxX < $1.maxX }) {
            left = GapMark(alongX: true, start: l.maxX, end: r.minX, cross: cross(r.minY, r.maxY, l.minY, l.maxY), equal: false)
        } else if edges, r.minX > 0.0005 { left = GapMark(alongX: true, start: 0, end: r.minX, cross: r.midY, equal: false) }
        if let rr = rowMates.filter({ $0.minX >= r.maxX - 0.0005 }).min(by: { $0.minX < $1.minX }) {
            right = GapMark(alongX: true, start: r.maxX, end: rr.minX, cross: cross(r.minY, r.maxY, rr.minY, rr.maxY), equal: false)
        } else if edges, r.maxX < 0.9995 { right = GapMark(alongX: true, start: r.maxX, end: 1, cross: r.midY, equal: false) }
        if let t = colMates.filter({ $0.maxY <= r.minY + 0.0005 }).max(by: { $0.maxY < $1.maxY }) {
            top = GapMark(alongX: false, start: t.maxY, end: r.minY, cross: cross(r.minX, r.maxX, t.minX, t.maxX), equal: false)
        } else if edges, r.minY > 0.0005 { top = GapMark(alongX: false, start: 0, end: r.minY, cross: r.midX, equal: false) }
        if let b = colMates.filter({ $0.minY >= r.maxY - 0.0005 }).min(by: { $0.minY < $1.minY }) {
            bottom = GapMark(alongX: false, start: r.maxY, end: b.minY, cross: cross(r.minX, r.maxX, b.minX, b.maxX), equal: false)
        } else if edges, r.maxY < 0.9995 { bottom = GapMark(alongX: false, start: r.maxY, end: 1, cross: r.midX, equal: false) }

        if var l = left, var rr = right, abs(l.pixels - rr.pixels) <= 1 { l.equal = true; rr.equal = true; left = l; right = rr }
        if var t = top, var b = bottom, abs(t.pixels - b.pixels) <= 1 { t.equal = true; b.equal = true; top = t; bottom = b }
        for g in [left, right, top, bottom] { if let g, g.end - g.start > 0.001 { out.append(g) } }
        return out
    }

    /// 핸들로 크기 조절. aspect = 높이/너비 (정규화) — 모서리에서만 적용
    static func resize(_ s: CGRect, _ h: CanvasHandle, dx: CGFloat, dy: CGFloat,
                       aspect: CGFloat?, drive: CanvasAxis? = nil) -> CGRect {
        let minSize: CGFloat = 0.02
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if h.movesLeft { minX = min(s.minX + dx, s.maxX - minSize) }
        if h.movesRight { maxX = max(s.maxX + dx, s.minX + minSize) }
        if h.movesTop { minY = min(s.minY + dy, s.maxY - minSize) }
        if h.movesBottom { maxY = max(s.maxY + dy, s.minY + minSize) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let aspect, h.isCorner else { return clip(r) }

        let byHeight: Bool
        if let drive { byHeight = drive == .horizontal }
        else { byHeight = abs(dy) / max(s.height, 0.001) > abs(dx) / max(s.width, 0.001) }
        if byHeight { r.size.width = r.height / aspect } else { r.size.height = r.width * aspect }

        // 화면 밖으로 나가지 않게 고정점 기준으로 줄이기
        let maxW = h.movesLeft ? s.maxX : 1 - s.minX
        let maxH = h.movesTop ? s.maxY : 1 - s.minY
        let w = min(r.width, maxW, maxH / aspect)
        r.size = CGSize(width: w, height: w * aspect)
        r.origin.x = h.movesLeft ? s.maxX - r.width : s.minX
        r.origin.y = h.movesTop ? s.maxY - r.height : s.minY
        return r
    }

    private static func clip(_ r: CGRect) -> CGRect {
        let c = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return c.isNull ? r : c
    }

    static func snapResize(start s: CGRect, handle h: CanvasHandle, dx: CGFloat, dy: CGFloat, aspect: CGFloat?,
                           others: [CGRect], guides: [CanvasGuide], threshold: CGSize, snap: Bool) -> Result {
        var r = resize(s, h, dx: dx, dy: dy, aspect: aspect)
        if snap {
            let xEdge: CGFloat? = h.movesLeft ? r.minX : h.movesRight ? r.maxX : nil
            let yEdge: CGFloat? = h.movesTop ? r.minY : h.movesBottom ? r.maxY : nil
            let sx = xEdge.flatMap { bestDelta([$0], targets(others, guides, .vertical), threshold: threshold.width) }
            let sy = yEdge.flatMap { bestDelta([$0], targets(others, guides, .horizontal), threshold: threshold.height) }
            if aspect != nil && h.isCorner {
                if let sx, sy == nil || abs(sx) / threshold.width <= abs(sy ?? 0) / threshold.height {
                    r = resize(s, h, dx: dx + sx, dy: dy, aspect: aspect, drive: .vertical)
                } else if let sy {
                    r = resize(s, h, dx: dx, dy: dy + sy, aspect: aspect, drive: .horizontal)
                }
            } else if sx != nil || sy != nil {
                r = resize(s, h, dx: dx + (sx ?? 0), dy: dy + (sy ?? 0), aspect: nil)
            }
        }
        return Result(rect: r, lines: lines(for: r, others, guides))
    }
}

// MARK: - 크롭 계산 (순수 함수)

enum CropMath {
    /// 엔진처럼 비율을 지키며 상자 안에 맞춘 영역. aspect = 너비/높이 (정규화)
    static func fit(aspect: CGFloat?, in frame: CGRect) -> CGRect {
        guard let aspect, aspect > 0, frame.width > 0, frame.height > 0 else { return frame }
        if frame.width / frame.height > aspect {
            let w = frame.height * aspect
            return CGRect(x: frame.midX - w / 2, y: frame.minY, width: w, height: frame.height)
        } else {
            let h = frame.width / aspect
            return CGRect(x: frame.minX, y: frame.midY - h / 2, width: frame.width, height: h)
        }
    }

    /// 보이는 영역 + 자른 양 → 자르기 전 전체 영역
    static func fullRect(content: CGRect, crop: NormalizedInsets) -> CGRect {
        let w = content.width / max(1 - crop.left - crop.right, 0.05)
        let h = content.height / max(1 - crop.top - crop.bottom, 0.05)
        return CGRect(x: content.minX - crop.left * w, y: content.minY - crop.top * h, width: w, height: h)
    }

    static func insets(window: CGRect, full: CGRect) -> NormalizedInsets {
        guard full.width > 0, full.height > 0 else { return .zero }
        func c(_ v: CGFloat) -> CGFloat { min(max(v, 0), 0.9) }
        return NormalizedInsets(top: c((window.minY - full.minY) / full.height),
                                left: c((window.minX - full.minX) / full.width),
                                bottom: c((full.maxY - window.maxY) / full.height),
                                right: c((full.maxX - window.maxX) / full.width))
    }

    /// 자르기 창의 가장자리를 끌기 — 전체 영역과 캔버스를 벗어나지 않고, 최소 10%는 남긴다
    static func drag(window s: CGRect, full: CGRect, handle h: CanvasHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minW = full.width * 0.1, minH = full.height * 0.1
        let lo = CGPoint(x: max(full.minX, 0), y: max(full.minY, 0))
        let hi = CGPoint(x: min(full.maxX, 1), y: min(full.maxY, 1))
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if h.movesLeft { minX = min(max(s.minX + dx, lo.x), s.maxX - minW) }
        if h.movesRight { maxX = max(min(s.maxX + dx, hi.x), s.minX + minW) }
        if h.movesTop { minY = min(max(s.minY + dy, lo.y), s.maxY - minH) }
        if h.movesBottom { maxY = max(min(s.maxY + dy, hi.y), s.minY + minH) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 자르기 모드에서 안쪽을 끌면 화면(전체 영역)이 움직인다. 자르기 창은 항상 전체 영역 안에 남는다
    static func pan(full f: CGRect, window w: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var r = f
        r.origin.x = min(max(f.minX + dx, w.maxX - f.width), w.minX)
        r.origin.y = min(max(f.minY + dy, w.maxY - f.height), w.minY)
        return r
    }

    /// 이미지 확대/축소 (anchor 기준). 자르기 창은 늘 이미지 안에 남는다
    static func zoom(full f: CGRect, window w: CGRect, scale: CGFloat, anchor: CGPoint) -> CGRect {
        guard f.width > 0, f.height > 0 else { return f }
        let minScale = max(w.width / f.width, w.height / f.height)
        let maxScale = max(minScale, (w.width * 12) / f.width)
        let s = min(max(scale, minScale), maxScale)
        var r = CGRect(x: anchor.x - (anchor.x - f.minX) * s, y: anchor.y - (anchor.y - f.minY) * s,
                       width: f.width * s, height: f.height * s)
        r.origin.x = min(max(r.minX, w.maxX - r.width), w.minX)
        r.origin.y = min(max(r.minY, w.maxY - r.height), w.minY)
        return r
    }

    /// 비율에 맞는 가장 큰 자르기 창 (지금 창의 가운데 기준, bounds 안)
    static func window(aspectHW a: CGFloat, around w: CGRect, in bounds: CGRect) -> CGRect {
        guard a > 0, bounds.width > 0, bounds.height > 0 else { return w }
        let width = min(bounds.width, bounds.height / a)
        var r = CGRect(x: w.midX - width / 2, y: w.midY - width * a / 2, width: width, height: width * a)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    static func fitsCanvas(_ r: CGRect) -> Bool {
        r.minX >= -0.001 && r.minY >= -0.001 && r.maxX <= 1.001 && r.maxY <= 1.001
    }
}

// MARK: - 편집 중 상태 (저장소와 분리 → 드래그가 다른 패널을 다시 그리지 않음)

@MainActor
@Observable
final class CanvasInteraction {
    enum Mode: Equatable { case none, move, resize(CanvasHandle), crop(CanvasHandle), cropWindow(CanvasHandle), pan, rotate, zoom, imageScale(CanvasHandle) }

    var mode: Mode = .none
    var itemID: SceneItem.ID?
    var startFrame: CGRect = .zero
    var startCrop: NormalizedInsets = .zero
    var liveFrame: CGRect?
    var liveCrop: NormalizedInsets?
    var liveAngle: Double?
    var startAngle: Double = 0
    var rotatePointerStart: Double = 0
    var cropFull: CGRect = .zero          // 자르기 계산용 전체 영역
    var lines: [GuideLine] = []
    var gaps: [GapMark] = []
    var badge: String?
    var hoverItemID: SceneItem.ID?

    // 자르기 모드
    var cropItemID: SceneItem.ID?
    var cropWindow: CGRect = .zero
    var cropStartFull: CGRect = .zero
    var cropStartWindow: CGRect = .zero
    var cropBaseFull: CGRect = .zero      // 자르기 모드에 들어올 때의 원본 크기 (확대 100%)
    var cropAspectHW: CGFloat?            // 비율 고정 (정규화 높이/너비)
    var cropOriginal: (frame: CGRect, crop: NormalizedInsets) = (.zero, .zero)

    // 가이드 끌기
    var guideDrag: (id: CanvasGuide.ID?, axis: CanvasAxis, position: CGFloat)?

    func begin(_ item: SceneItem, _ mode: Mode, frame: CGRect) {
        self.mode = mode; itemID = item.id
        startFrame = frame; startCrop = item.crop
        liveFrame = frame; liveCrop = nil; liveAngle = nil
    }

    func end() {
        mode = .none; itemID = nil; liveFrame = nil; liveCrop = nil; liveAngle = nil
        lines = []; gaps = []; badge = nil
    }
}

// MARK: - 캔버스 + 룰러

struct CanvasStageView: View {
    @Bindable var store: ShowStore
    var compositePreview: AnyView?
    var sourcePreview: (Source) -> AnyView

    @State private var ix = CanvasInteraction()
    @State private var canvasSize: CGSize = .zero
    @AppStorage("canvas.showRulers") private var showRulers = true
    @AppStorage("canvas.showGuides") private var showGuides = true
    @AppStorage("canvas.snap") private var snapOn = true
    @AppStorage("canvas.safeArea") private var showSafeArea = false
    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    private var ruler: CGFloat { showRulers ? CanvasStyle.rulerSize : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            stage
        }
        .onChange(of: store.cropRequest) {
            guard let id = store.cropRequest else { return }
            store.cropRequest = nil
            if let item = store.selectedScene?.items.first(where: { $0.id == id }) { enterCrop(item) }
        }
        .onChange(of: store.selectedSceneID) { if ix.cropItemID != nil { exitCrop(commit: true) }; ix.end() }
    }

    // MARK: 도구 막대

    private var toolbar: some View {
        HStack(spacing: 8) {
            Toggle("룰러", systemImage: "ruler", isOn: $showRulers).help("룰러 보기 (⇧R)")
            Toggle("가이드", systemImage: "squareshape.split.3x3", isOn: $showGuides).help("룰러에서 끌어 만든 가이드 보기")
            Toggle("스냅", systemImage: "dot.squareshape.split.2x2", isOn: $snapOn).help("정렬선·간격에 자동으로 붙기 (드래그 중 ⌘로 잠시 끄기)")
            Toggle("안전 영역", systemImage: "rectangle.dashed", isOn: $showSafeArea).help("TV·프로젝터에서 잘릴 수 있는 가장자리 표시")
            if !store.guides.isEmpty {
                Button("가이드 지우기") { store.guides.removeAll() }.buttonStyle(.borderless)
            }
            Spacer()
            Text(ix.cropItemID != nil ? L("자르기: 안쪽을 끌어 화면 이동 · 모서리로 범위 조절 · ⏎ 완료 · ⎋ 취소")
                                      : L("아래 ↻ 회전 · ⌥ 자르기 · ⇧ 비율 해제 · ⌘ 스냅 끄기 · 오른쪽 클릭 메뉴 · 파일을 끌어 놓아 추가"))
                .font(.uiCaption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .toggleStyle(ChurchToolToggleStyle())
        .controlSize(.regular)
    }

    // MARK: 무대 (룰러 + 캔버스)

    private var stage: some View {
        canvas
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .padding(.leading, ruler)
            .padding(.top, ruler)
            .overlay(alignment: .topLeading) {
                if showRulers {
                    GeometryReader { g in
                        let w = g.size.width - ruler, h = g.size.height - ruler
                        RulerCorner().frame(width: ruler, height: ruler)
                        RulerView(alongX: true, highlight: highlightRange(alongX: true), guides: rulerGuideMarks(.vertical))
                            .frame(width: max(w, 0), height: ruler)
                            .contentShape(Rectangle())
                            .gesture(rulerGesture(axis: .horizontal))
                            .help("아래로 끌어 가로 가이드 만들기")
                            .offset(x: ruler)
                        RulerView(alongX: false, highlight: highlightRange(alongX: false), guides: rulerGuideMarks(.horizontal))
                            .frame(width: ruler, height: max(h, 0))
                            .contentShape(Rectangle())
                            .gesture(rulerGesture(axis: .vertical))
                            .help("오른쪽으로 끌어 세로 가이드 만들기")
                            .offset(y: ruler)
                    }
                }
            }
            .coordinateSpace(.named("stage"))
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // 실제 엔진 화면
                ZStack {
                    Color.black
                    if let compositePreview { compositePreview.allowsHitTesting(false) }
                }
                .clipShape(Rectangle())

                // 빈 곳 클릭 = 선택 해제
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if ix.cropItemID != nil { exitCrop(commit: true) }
                        store.selectedItemID = nil
                        focused = true
                    }

                if showSafeArea { SafeAreaOverlay().allowsHitTesting(false) }

                if let scene = store.selectedScene {
                    ForEach(visualItems(scene)) { item in itemLayer(item, size) }
                }

                if showGuides { userGuideLayer(size) }
                selectionLayer(size)
                cropLayer(size)
                SmartGuideOverlay(lines: ix.lines, gaps: ix.gaps).allowsHitTesting(false)
                badgeLayer(size)
            }
            .onAppear { canvasSize = size }
            .onChange(of: size) { canvasSize = size }
            // Finder 파일, 미디어 썸네일, 그래픽 아이콘을 끌어 놓으면 그 자리에 추가
            .dropDestination(for: URL.self) { urls, location in
                guard editable, store.selectedScene != nil, !urls.isEmpty else { return false }
                let p = CGPoint(x: min(max(location.x / max(size.width, 1), 0), 1), y: min(max(location.y / max(size.height, 1), 0), 1))
                StudioInsert.drop(urls, into: store, at: p, color: UserDefaults.standard.string(forKey: "graphics.color") ?? "FFFFFF")
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    Rectangle().strokeBorder(CanvasStyle.selection, lineWidth: 3)
                        .overlay(Text("여기에 놓으면 장면에 추가됩니다").font(.uiCallout.weight(.semibold)).padding(8)
                            .churchGlass())
                        .allowsHitTesting(false)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    // MARK: 데이터 도우미

    private func visualItems(_ scene: ShowScene) -> [SceneItem] {
        scene.items.filter { item in
            guard item.isVisible, let s = store.source(item.sourceID) else { return false }
            return s.kind.isVisual
        }
    }

    private func isPhotoLike(_ item: SceneItem) -> Bool {
        guard let s = store.source(item.sourceID) else { return false }
        switch s.config {
        case .camera, .window, .screen, .graphic, .captions, .slides, .youtube: return true
        case let .media(_, _, audioOnly): return !audioOnly
        default: return false
        }
    }

    /// 화면에 그릴 프레임: 지금 끌고 있으면 실시간 값, 아니면 저장값
    private func displayFrame(_ item: SceneItem) -> CGRect {
        if ix.itemID == item.id, let live = ix.liveFrame { return live }
        return item.frame
    }

    private func otherRects(_ item: SceneItem) -> [CGRect] {
        guard let scene = store.selectedScene else { return [] }
        return visualItems(scene).filter { $0.id != item.id }.map { rotatedBounds($0.frame, angle: $0.angle) }
    }

    private var activeGuides: [CanvasGuide] { showGuides ? store.guides : [] }

    private func threshold(_ size: CGSize) -> CGSize {
        CGSize(width: CanvasStyle.snapDistance / max(size.width, 1), height: CanvasStyle.snapDistance / max(size.height, 1))
    }

    private func scaled(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func sizeLabel(_ r: CGRect) -> String {
        "\(Int((r.width * OutputCanvas.width).rounded())) × \(Int((r.height * OutputCanvas.height).rounded()))"
    }

    /// 모서리 크기 조절 때 지킬 비율 (높이/너비, 정규화)
    private func aspectHW(_ item: SceneItem, current: CGRect) -> CGFloat {
        if isPhotoLike(item), let a = store.contentAspect(item), a > 0 { return 1 / a }
        return current.height / max(current.width, 0.0001)
    }

    private var editable: Bool { !store.editingLocked }

    // MARK: 레이어 — 각 소스 (선택 · 이동 · 호버)

    private func displayAngle(_ item: SceneItem) -> Double {
        if ix.itemID == item.id, let a = ix.liveAngle { return a }
        return item.angle
    }

    /// 돌린 상자를 감싸는 축 정렬 영역 (정규화) — 스냅·간격 계산용
    private func rotatedBounds(_ r: CGRect, angle: Double) -> CGRect {
        guard abs(angle) > 0.01, canvasSize.width > 0, canvasSize.height > 0 else { return r }
        let s = canvasSize
        let w = r.width * s.width, h = r.height * s.height
        let t = angle * .pi / 180
        let bw = abs(w * cos(t)) + abs(h * sin(t)), bh = abs(w * sin(t)) + abs(h * cos(t))
        return CGRect(x: r.midX - bw / s.width / 2, y: r.midY - bh / s.height / 2, width: bw / s.width, height: bh / s.height)
    }

    @ViewBuilder
    private func itemLayer(_ item: SceneItem, _ size: CGSize) -> some View {
        if let src = store.source(item.sourceID) {
            let rect = scaled(displayFrame(item), size)
            sourcePreview(src)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .contentShape(Rectangle())
                .overlay {
                    if let warning = store.sourceWarnings[src.id] { MissingSourceView(name: src.name, reason: warning) }
                }
                .overlay {
                    if ix.hoverItemID == item.id && store.selectedItemID != item.id && ix.mode == .none {
                        Rectangle().stroke(CanvasStyle.selection.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .rotationEffect(.degrees(displayAngle(item)))
                .position(x: rect.midX, y: rect.midY)
                .onHover { inside in
                    if inside { ix.hoverItemID = item.id } else if ix.hoverItemID == item.id { ix.hoverItemID = nil }
                }
                .gesture(moveGesture(item, size))
                .simultaneousGesture(TapGesture(count: 2).onEnded { enterCrop(item) })
                .onTapGesture { select(item) }
                .contextMenu { itemMenu(item) }
        }
    }

    private func select(_ item: SceneItem) {
        if ix.cropItemID != nil && ix.cropItemID != item.id { exitCrop(commit: true) }
        if store.selectedItemID != item.id { store.selectedItemID = item.id }
        focused = true
    }

    private func moveGesture(_ item: SceneItem, _ size: CGSize) -> some Gesture {
        // 돌린 상자 위에서도 화면 기준으로 움직이도록 회전되지 않은 좌표(stage)로 잰다
        DragGesture(minimumDistance: 2, coordinateSpace: .named("stage"))
            .onChanged { v in
                guard editable, !item.isLocked, ix.cropItemID == nil else { return }
                if ix.itemID != item.id || ix.mode != .move {
                    ix.begin(item, .move, frame: item.frame)
                    if store.selectedItemID != item.id { store.selectedItemID = item.id }
                    focused = true
                    NSCursor.closedHand.set()
                }
                let flags = NSEvent.modifierFlags
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                if flags.contains(.shift) { if abs(dx * size.width) > abs(dy * size.height) { dy = 0 } else { dx = 0 } }
                // 돌린 소스는 감싸는 영역으로 정렬선·간격을 계산하고, 움직인 만큼 실제 상자를 옮긴다
                let startBox = rotatedBounds(ix.startFrame, angle: item.angle)
                let res = SmartGuides.snapMove(startBox.offsetBy(dx: dx, dy: dy), others: otherRects(item),
                                               guides: activeGuides, threshold: threshold(size),
                                               snap: snapOn && !flags.contains(.command), edgeGaps: flags.contains(.option))
                let moved = SmartGuides.keepInside(ix.startFrame.offsetBy(dx: res.rect.minX - startBox.minX, dy: res.rect.minY - startBox.minY))
                ix.liveFrame = moved; ix.lines = res.lines; ix.gaps = res.gaps
                store.previewLayout(item.id, frame: moved, crop: item.crop)
            }
            .onEnded { _ in commitDrag() }
    }

    private func commitDrag() {
        defer { ix.end(); NSCursor.arrow.set() }
        guard let id = ix.itemID, ix.mode != .none else { return }
        let frame = ix.liveFrame, crop = ix.liveCrop, angle = ix.liveAngle
        store.updateItem(id) { item in
            if let frame { item.frame = frame }
            if let crop { item.crop = crop }
            if let angle { item.angle = angle }
        }
    }

    // MARK: 레이어 — 선택 테두리·핸들·회전 손잡이 (Canva 모양, 소스와 함께 돈다)

    private func showHandle(_ h: CanvasHandle, rect: CGRect, photo: Bool, rotated: Bool) -> Bool {
        if h.isCorner { return true }
        if rotated && photo { return false }      // 돌린 사진류는 모서리로만 (비율 유지)
        return h.isVerticalSide ? rect.height > 44 : rect.width > 44
    }

    @ViewBuilder
    private func selectionLayer(_ size: CGSize) -> some View {
        if ix.cropItemID == nil, let item = store.selectedItem, item.isVisible,
           let src = store.source(item.sourceID), src.kind.isVisual {
            let rect = scaled(displayFrame(item), size)
            let angle = displayAngle(item)
            let rotated = abs(angle) > 0.01
            let local = CGRect(origin: .zero, size: rect.size)
            let contentAbs = scaled(ix.itemID == item.id ? displayFrame(item) : store.contentRect(item), size)
            let content = contentAbs.offsetBy(dx: -rect.minX, dy: -rect.minY)

            ZStack(alignment: .topLeading) {
                // 선택된 소스는 다른 소스 위에서도 바로 끌 수 있게 맨 위에 잡는 영역을 둔다
                Color.clear
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .contentShape(Rectangle())
                    .gesture(moveGesture(item, size))
                    .simultaneousGesture(TapGesture(count: 2).onEnded { enterCrop(item) })
                    .contextMenu { itemMenu(item) }

                Rectangle()
                    .stroke(CanvasStyle.selection, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .allowsHitTesting(false)

                // 상자 안에 빈 띠가 있으면 실제 화면 영역을 점선으로
                if abs(content.width - rect.width) > 2 || abs(content.height - rect.height) > 2 {
                    Rectangle()
                        .stroke(CanvasStyle.selection.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: content.width, height: content.height)
                        .position(x: content.midX, y: content.midY)
                        .allowsHitTesting(false)
                }

                if item.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.uiCaption)
                        .padding(5)
                        .background(CanvasStyle.selection, in: Circle())
                        .foregroundStyle(.white)
                        .position(x: local.maxX, y: 0)
                        .allowsHitTesting(false)
                } else if editable {
                    ForEach(CanvasHandle.allCases, id: \.self) { h in
                        if showHandle(h, rect: rect, photo: isPhotoLike(item), rotated: rotated) {
                            CanvasHandleView(handle: h)
                                .position(h.point(in: local))
                                .gesture(handleGesture(item, h, size))
                                .onHover { inside in (inside ? h.cursor : NSCursor.arrow).set() }
                        }
                    }
                    // 회전 손잡이: 아래 가운데 (Canva와 같은 자리)
                    Rectangle()
                        .fill(CanvasStyle.selection)
                        .frame(width: 1.5, height: 12)
                        .position(x: local.midX, y: local.maxY + 8)
                        .allowsHitTesting(false)
                    RotateHandleView()
                        .position(x: local.midX, y: local.maxY + 26)
                        .gesture(rotateGesture(item, size))
                        .onTapGesture(count: 2) { store.rotate(item.id, to: 0) }
                        .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
                        .help("끌어서 돌리기 · 0·45·90°에 붙음 · ⇧ 15° 단위 · 더블클릭하면 0°")
                }
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1), alignment: .topLeading)
            .rotationEffect(.degrees(angle))
            .position(x: rect.midX, y: rect.midY)
        }
    }

    /// 반대쪽 손잡이가 화면에서 제자리에 있도록 (돌린 상자 크기 조절)
    private func anchored(_ r: CGRect, start s: CGRect, handle h: CanvasHandle, angle: Double, size: CGSize) -> CGRect {
        func opposite(_ rect: CGRect) -> CGPoint {
            let x: CGFloat = h.movesLeft ? rect.maxX : h.movesRight ? rect.minX : rect.midX
            let y: CGFloat = h.movesTop ? rect.maxY : h.movesBottom ? rect.minY : rect.midY
            return CGPoint(x: x, y: y)
        }
        func world(_ p: CGPoint, around rect: CGRect) -> CGPoint {
            let c = CGPoint(x: rect.midX * size.width, y: rect.midY * size.height)
            let px = p.x * size.width - c.x, py = p.y * size.height - c.y
            let t = angle * .pi / 180
            return CGPoint(x: c.x + px * cos(t) - py * sin(t), y: c.y + px * sin(t) + py * cos(t))
        }
        let before = world(opposite(s), around: s), after = world(opposite(r), around: r)
        return r.offsetBy(dx: (before.x - after.x) / size.width, dy: (before.y - after.y) / size.height)
    }

    private func handleGesture(_ item: SceneItem, _ h: CanvasHandle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("stage"))
            .onChanged { v in
                guard editable else { return }
                let flags = NSEvent.modifierFlags
                let angle = item.angle
                let rotated = abs(angle) > 0.01
                if ix.itemID != item.id || ix.mode == .none {
                    let wantsCrop = !rotated && (flags.contains(.option) || (isPhotoLike(item) && !h.isCorner))
                    let content = store.contentRect(item)
                    if wantsCrop {
                        ix.begin(item, .crop(h), frame: content)
                        ix.cropFull = CropMath.fullRect(content: content, crop: item.crop)
                    } else {
                        // 사진류는 실제 화면 영역에서 시작 → 상자가 화면에 딱 맞게 된다
                        ix.begin(item, .resize(h), frame: isPhotoLike(item) ? content : item.frame)
                    }
                    if store.selectedItemID != item.id { store.selectedItemID = item.id }
                }
                // 돌린 상자는 끈 거리를 상자 방향으로 바꿔 계산
                let t = -angle * .pi / 180
                let tx = v.translation.width, ty = v.translation.height
                let dx = (tx * cos(t) - ty * sin(t)) / size.width
                let dy = (tx * sin(t) + ty * cos(t)) / size.height
                switch ix.mode {
                case .resize(let handle):
                    let aspect: CGFloat? = (handle.isCorner && !flags.contains(.shift)) ? aspectHW(item, current: ix.startFrame) : nil
                    if rotated {
                        let r = anchored(SmartGuides.resize(ix.startFrame, handle, dx: dx, dy: dy, aspect: aspect),
                                         start: ix.startFrame, handle: handle, angle: angle, size: size)
                        ix.liveFrame = r; ix.lines = []; ix.gaps = []
                        ix.badge = sizeLabel(r)
                        store.previewLayout(item.id, frame: r, crop: item.crop)
                    } else {
                        let res = SmartGuides.snapResize(start: ix.startFrame, handle: handle, dx: dx, dy: dy, aspect: aspect,
                                                         others: otherRects(item), guides: activeGuides,
                                                         threshold: threshold(size), snap: snapOn && !flags.contains(.command))
                        ix.liveFrame = res.rect; ix.lines = res.lines; ix.gaps = []
                        ix.badge = sizeLabel(res.rect)
                        store.previewLayout(item.id, frame: res.rect, crop: item.crop)
                    }
                case .crop(let handle):
                    let window = CropMath.drag(window: ix.startFrame, full: ix.cropFull, handle: handle, dx: dx, dy: dy)
                    let crop = CropMath.insets(window: window, full: ix.cropFull)
                    ix.liveFrame = window; ix.liveCrop = crop
                    ix.badge = L("자르기 ") + sizeLabel(window)
                    store.previewLayout(item.id, frame: window, crop: crop)
                default: break
                }
            }
            .onEnded { _ in commitDrag() }
    }

    /// 회전 손잡이: 소스 중심을 축으로 포인터 각도만큼 돌린다. 0·45·90°… 근처(4°)에서 붙고, ⇧는 15° 단위
    private func rotateGesture(_ item: SceneItem, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("stage"))
            .onChanged { v in
                guard editable, !item.isLocked else { return }
                let r = scaled(item.frame, size)
                let c = CGPoint(x: ruler + r.midX, y: ruler + r.midY)
                let pointer = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi
                if ix.itemID != item.id || ix.mode != .rotate {
                    ix.begin(item, .rotate, frame: item.frame)
                    ix.startAngle = item.angle
                    ix.rotatePointerStart = atan2(v.startLocation.y - c.y, v.startLocation.x - c.x) * 180 / .pi
                    if store.selectedItemID != item.id { store.selectedItemID = item.id }
                }
                var a = ix.startAngle + (pointer - ix.rotatePointerStart)
                if NSEvent.modifierFlags.contains(.shift) { a = (a / 15).rounded() * 15 }
                else { let near = (a / 45).rounded() * 45; if abs(a - near) < 4 { a = near } }
                var normalized = item; normalized.angle = a          // -180…180으로 정리
                ix.liveAngle = normalized.angle
                ix.badge = "\(Int(normalized.angle.rounded()))°"
                store.previewLayout(item.id, frame: item.frame, crop: item.crop, angle: normalized.angle)
            }
            .onEnded { _ in commitDrag() }
    }

    /// 오른쪽 클릭 메뉴 (Canva와 같은 항목)
    @ViewBuilder
    private func itemMenu(_ item: SceneItem) -> some View {
        Button("복제  ⌘D") { store.selectedItemID = item.id; store.duplicateItem(item.id) }
        Button("복사  ⌘C") { store.copyItem(item.id) }
        Button("붙여넣기  ⌘V") { store.pasteItem() }
        Divider()
        Button("맨 앞으로  ⌥⌘]") { store.reorder(item.id, .front) }
        Button("앞으로  ⌘]") { store.reorder(item.id, .forward) }
        Button("뒤로  ⌘[") { store.reorder(item.id, .backward) }
        Button("맨 뒤로  ⌥⌘[") { store.reorder(item.id, .back) }
        Divider()
        Button("오른쪽으로 90° 돌리기") { store.rotate(item.id, to: item.angle + 90) }
        if item.angle != 0 { Button("회전 0°로") { store.rotate(item.id, to: 0) } }
        if item.angle == 0 { Button("자르기  ⏎") { enterCrop(item) } }
        Button("화면에 맞춤") { store.fitFrameToContent(item.id) }
        Button(item.isLocked ? L("잠금 해제") : L("잠그기")) { store.updateItem(item.id) { $0.isLocked.toggle() } }
        Divider()
        Button("삭제  ⌫", role: .destructive) { store.removeItem(item.id) }
    }

    // MARK: 레이어 — 자르기 모드

    private func enterCrop(_ item: SceneItem) {
        guard editable, !item.isLocked, ix.cropItemID != item.id else { return }
        guard item.angle == 0 else { store.lastError = L("회전을 0°로 되돌린 뒤 자를 수 있습니다. (오른쪽 클릭 › 회전 0°로)"); return }
        if ix.cropItemID != nil { exitCrop(commit: true) }
        store.selectedItemID = item.id
        let content = store.contentRect(item)
        ix.end()
        ix.cropItemID = item.id
        ix.cropOriginal = (item.frame, item.crop)
        ix.cropFull = CropMath.fullRect(content: content, crop: item.crop)
        ix.cropBaseFull = ix.cropFull
        ix.cropAspectHW = item.shape == .circle ? content.height / max(content.width, 0.0001) : nil
        ix.cropWindow = content
        pushCropPreview()
        focused = true
    }

    /// 자르기 모드에서는 가능한 한 전체 화면을 엔진에 보여 주고 바깥을 어둡게 덮는다
    private func pushCropPreview() {
        guard let id = ix.cropItemID else { return }
        if CropMath.fitsCanvas(ix.cropFull) {
            store.previewLayout(id, frame: ix.cropFull, crop: .zero)
        } else {
            store.previewLayout(id, frame: ix.cropWindow, crop: CropMath.insets(window: ix.cropWindow, full: ix.cropFull))
        }
    }

    private func exitCrop(commit: Bool) {
        guard let id = ix.cropItemID else { return }
        if commit {
            let window = ix.cropWindow, crop = CropMath.insets(window: window, full: ix.cropFull)
            store.previewLayout(id, frame: window, crop: crop)
            store.updateItem(id) { $0.frame = window; $0.crop = crop }
        } else {
            store.previewLayout(id, frame: ix.cropOriginal.frame, crop: ix.cropOriginal.crop)
        }
        ix.cropItemID = nil
        ix.end()
    }

    private var cropItem: SceneItem? {
        guard let id = ix.cropItemID else { return nil }
        return store.selectedScene?.items.first { $0.id == id }
    }

    /// 자르기 창이 움직일 수 있는 범위 (이미지 ∩ 화면)
    private var cropBounds: CGRect {
        let b = ix.cropFull.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return b.isNull ? ix.cropFull : b
    }

    private var cropZoom: CGFloat { ix.cropFull.width / max(ix.cropBaseFull.width, 0.0001) }

    private func setCropZoom(_ z: CGFloat) {
        let target = ix.cropBaseFull.width * z
        ix.cropFull = CropMath.zoom(full: ix.cropFull, window: ix.cropWindow, scale: target / max(ix.cropFull.width, 0.0001),
                                    anchor: CGPoint(x: ix.cropWindow.midX, y: ix.cropWindow.midY))
        pushCropPreview()
    }

    private func setCropAspect(_ hw: CGFloat?) {
        ix.cropAspectHW = hw
        if let hw { ix.cropWindow = CropMath.window(aspectHW: hw, around: ix.cropWindow, in: cropBounds); pushCropPreview() }
    }

    /// 화면 픽셀 비율(가로:세로) → 정규화 높이/너비
    private func hw(_ w: CGFloat, _ h: CGFloat) -> CGFloat { (h / w) * (OutputCanvas.width / OutputCanvas.height) }

    @ViewBuilder
    private func cropLayer(_ size: CGSize) -> some View {
        if ix.cropItemID != nil {
            let full = scaled(ix.cropFull, size), win = scaled(ix.cropWindow, size)
            let shape = cropItem?.shape ?? .rect

            // 자르기 창 밖은 어둡게 (Canva처럼 바깥 이미지는 흐리게 보인다)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(win)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: full.width, height: full.height)
                .position(x: full.midX, y: full.midY)
                .allowsHitTesting(false)

            // 삼등분선
            Path { p in
                for i in 1...2 {
                    let x = win.minX + win.width * CGFloat(i) / 3, y = win.minY + win.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: win.minY)); p.addLine(to: CGPoint(x: x, y: win.maxY))
                    p.move(to: CGPoint(x: win.minX, y: y)); p.addLine(to: CGPoint(x: win.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: win.width, height: win.height)
                .position(x: win.midX, y: win.midY)
                .allowsHitTesting(false)

            // 모양 윤곽 (둥근 모서리·원이 어디까지 보이는지)
            if shape != .rect {
                shape.shape(in: win.size)
                    .stroke(CanvasStyle.selection, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .frame(width: win.width, height: win.height)
                    .position(x: win.midX, y: win.midY)
                    .allowsHitTesting(false)
            }

            // 안쪽을 끌면 이미지 이동, 트랙패드 핀치로 확대·축소
            Color.clear
                .frame(width: max(win.width, 1), height: max(win.height, 1))
                .contentShape(Rectangle())
                .position(x: win.midX, y: win.midY)
                .gesture(panGesture(size))
                .simultaneousGesture(zoomGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded { exitCrop(commit: true) })
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }

            // 이미지 모서리: 끌어서 이미지 크기 조절 (자르기 창은 그대로)
            ForEach([CanvasHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                let pt = h.point(in: full)
                if pt.x >= -2 && pt.y >= -2 && pt.x <= size.width + 2 && pt.y <= size.height + 2 {
                    ImageScaleHandleView()
                        .position(pt)
                        .gesture(imageScaleGesture(h, size))
                        .onHover { inside in (inside ? h.cursor : NSCursor.arrow).set() }
                        .help("끌어서 이미지 확대·축소")
                }
            }

            ForEach(CanvasHandle.allCases, id: \.self) { h in
                if h.isCorner || ix.cropAspectHW == nil {
                    CropHandleView(handle: h)
                        .position(h.point(in: win))
                        .gesture(cropWindowGesture(h, size))
                        .onHover { inside in (inside ? h.cursor : NSCursor.arrow).set() }
                }
            }

            cropToolbar
                .position(x: min(max(win.midX, 230), size.width - 230), y: win.minY > 40 ? win.minY - 22 : min(win.maxY + 22, size.height - 18))
        }
    }

    private var cropToolbar: some View {
        HStack(spacing: 8) {
            Text(sizeLabel(ix.cropWindow)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Button("자유") { setCropAspect(nil) }
                Button("원본 비율") { setCropAspect(ix.cropBaseFull.height / max(ix.cropBaseFull.width, 0.0001)) }
                Divider()
                Button("16:9") { setCropAspect(hw(16, 9)) }
                Button("4:3") { setCropAspect(hw(4, 3)) }
                Button("1:1") { setCropAspect(hw(1, 1)) }
                Button("3:4") { setCropAspect(hw(3, 4)) }
                Button("9:16") { setCropAspect(hw(9, 16)) }
            } label: { Text(ix.cropAspectHW == nil ? L("비율: 자유") : L("비율 고정")) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            HStack(spacing: 3) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(min(max(cropZoom, 1), 4)) }, set: { setCropZoom(CGFloat($0)) }), in: 1...4)
                    .frame(width: 80)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .help("이미지 확대 (트랙패드 핀치도 됩니다)")
            Button("초기화") {
                ix.cropFull = ix.cropBaseFull
                ix.cropAspectHW = nil
                ix.cropWindow = cropBounds
                pushCropPreview()
            }
            Button("취소") { exitCrop(commit: false) }
            Button("완료") { exitCrop(commit: true) }.churchProminentButton()
        }
        .controlSize(.regular)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .churchGlass()
        .fixedSize()
    }

    private func panGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if ix.mode != .pan { ix.mode = .pan; ix.cropStartFull = ix.cropFull; NSCursor.closedHand.set() }
                ix.cropFull = CropMath.pan(full: ix.cropStartFull, window: ix.cropWindow,
                                           dx: v.translation.width / size.width, dy: v.translation.height / size.height)
                pushCropPreview()
            }
            .onEnded { _ in ix.mode = .none; NSCursor.openHand.set() }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if ix.mode != .zoom { ix.mode = .zoom; ix.cropStartFull = ix.cropFull }
                ix.cropFull = CropMath.zoom(full: ix.cropStartFull, window: ix.cropWindow, scale: v.magnification,
                                            anchor: CGPoint(x: ix.cropWindow.midX, y: ix.cropWindow.midY))
                pushCropPreview()
            }
            .onEnded { _ in ix.mode = .none }
    }

    /// 이미지 모서리 끌기: 반대쪽 모서리를 고정하고 비율을 지키며 확대·축소
    private func imageScaleGesture(_ h: CanvasHandle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if ix.mode != .imageScale(h) { ix.mode = .imageScale(h); ix.cropStartFull = ix.cropFull }
                let s = ix.cropStartFull
                let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let sx = (s.width + (h.movesRight ? dx : -dx)) / max(s.width, 0.0001)
                let sy = (s.height + (h.movesBottom ? dy : -dy)) / max(s.height, 0.0001)
                let anchor = CGPoint(x: h.movesLeft ? s.maxX : s.minX, y: h.movesTop ? s.maxY : s.minY)
                ix.cropFull = CropMath.zoom(full: s, window: ix.cropWindow, scale: max(sx, sy), anchor: anchor)
                ix.badge = "확대 \(Int((cropZoom * 100).rounded()))%"
                pushCropPreview()
            }
            .onEnded { _ in ix.mode = .none; ix.badge = nil }
    }

    private func cropWindowGesture(_ h: CanvasHandle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if ix.mode != .cropWindow(h) { ix.mode = .cropWindow(h); ix.cropStartWindow = ix.cropWindow }
                let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let lock = ix.cropAspectHW ?? (NSEvent.modifierFlags.contains(.shift) && h.isCorner
                                               ? ix.cropStartWindow.height / max(ix.cropStartWindow.width, 0.0001) : nil)
                if let lock, h.isCorner {
                    // 비율 고정: 범위를 벗어나면 그 자리에서 멈춘다
                    let r = SmartGuides.resize(ix.cropStartWindow, h, dx: dx, dy: dy, aspect: lock)
                    let b = cropBounds.insetBy(dx: -0.0005, dy: -0.0005)
                    if b.contains(r), r.width >= ix.cropFull.width * 0.05 { ix.cropWindow = r }
                } else {
                    ix.cropWindow = CropMath.drag(window: ix.cropStartWindow, full: ix.cropFull, handle: h, dx: dx, dy: dy)
                }
                ix.badge = L("자르기 ") + sizeLabel(ix.cropWindow)
                if !CropMath.fitsCanvas(ix.cropFull) { pushCropPreview() }   // 전체가 보이는 경우엔 덮개만 바뀌면 됨
            }
            .onEnded { _ in ix.mode = .none; ix.badge = nil }
    }

    // MARK: 레이어 — 룰러 가이드

    @ViewBuilder
    private func userGuideLayer(_ size: CGSize) -> some View {
        ForEach(store.guides) { g in
            let pos = (ix.guideDrag?.id == g.id ? ix.guideDrag?.position : nil) ?? g.position
            guideLine(axis: g.axis, position: pos, size: size, live: ix.guideDrag?.id == g.id)
                .gesture(guideMoveGesture(g, size))
                .onTapGesture(count: 2) { store.removeGuide(g.id) }
                .contextMenu {
                    Button("이 가이드 삭제") { store.removeGuide(g.id) }
                    Button("모든 가이드 삭제", role: .destructive) { store.guides.removeAll() }
                }
                .onHover { inside in (inside ? (g.axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set() }
        }
        // 룰러에서 새로 끌어오는 중
        if let d = ix.guideDrag, d.id == nil, (0...1).contains(d.position) {
            guideLine(axis: d.axis, position: d.position, size: size, live: true).allowsHitTesting(false)
        }
    }

    private func guideLine(axis: CanvasAxis, position: CGFloat, size: CGSize, live: Bool) -> some View {
        let vertical = axis == .vertical
        let p = vertical ? position * size.width : position * size.height
        return ZStack {
            Rectangle().fill(CanvasStyle.userGuide).frame(width: vertical ? 1 : size.width, height: vertical ? size.height : 1)
            if live {
                Text("\(Int((position * (vertical ? OutputCanvas.width : OutputCanvas.height)).rounded()))")
                    .font(.uiCaption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(CanvasStyle.userGuide, in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
                    .foregroundStyle(.black)
                    .offset(x: vertical ? 22 : 0, y: vertical ? 0 : -12)
            }
        }
        .frame(width: vertical ? 9 : size.width, height: vertical ? size.height : 9)
        .contentShape(Rectangle())
        .position(x: vertical ? p : size.width / 2, y: vertical ? size.height / 2 : p)
    }

    /// 가이드도 화면 중앙·소스 가장자리에 붙는다
    private func snapGuide(_ axis: CanvasAxis, _ p: CGFloat) -> CGFloat {
        guard snapOn, let scene = store.selectedScene else { return p }
        let rects = visualItems(scene).map(\.frame)
        let t = SmartGuides.targets(rects, [], axis)
        let thr = axis == .vertical ? threshold(canvasSize).width : threshold(canvasSize).height
        return p + (SmartGuides.bestDelta([p], t, threshold: thr) ?? 0)
    }

    private func guideMoveGesture(_ g: CanvasGuide, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("stage"))
            .onChanged { v in
                let raw = g.axis == .vertical ? (v.location.x - ruler) / size.width : (v.location.y - ruler) / size.height
                ix.guideDrag = (g.id, g.axis, (0...1).contains(raw) ? snapGuide(g.axis, raw) : raw)
            }
            .onEnded { _ in
                if let d = ix.guideDrag {
                    if d.position < -0.01 || d.position > 1.01 { store.removeGuide(g.id) }   // 룰러 밖으로 끌면 삭제
                    else { store.moveGuide(g.id, to: d.position) }
                }
                ix.guideDrag = nil
            }
    }

    /// 위 룰러 → 가로 가이드, 왼쪽 룰러 → 세로 가이드
    private func rulerGesture(axis: CanvasAxis) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("stage"))
            .onChanged { v in
                showGuides = true
                let raw = axis == .vertical ? (v.location.x - ruler) / max(canvasSize.width, 1)
                                            : (v.location.y - ruler) / max(canvasSize.height, 1)
                ix.guideDrag = (nil, axis, (0...1).contains(raw) ? snapGuide(axis, raw) : raw)
            }
            .onEnded { _ in
                if let d = ix.guideDrag, (0...1).contains(d.position) { store.addGuide(axis, at: d.position) }
                ix.guideDrag = nil
            }
    }

    private func rulerGuideMarks(_ axis: CanvasAxis) -> [CGFloat] {
        guard showGuides else { return [] }
        return store.guides.filter { $0.axis == axis }.map(\.position)
    }

    private func highlightRange(alongX: Bool) -> ClosedRange<CGFloat>? {
        if ix.cropItemID != nil {
            return alongX ? ix.cropWindow.minX...ix.cropWindow.maxX : ix.cropWindow.minY...ix.cropWindow.maxY
        }
        guard let item = store.selectedItem, item.isVisible else { return nil }
        let f = displayFrame(item)
        guard f.width > 0, f.height > 0 else { return nil }
        return alongX ? f.minX...f.maxX : f.minY...f.maxY
    }

    // MARK: 배지 (크기 표시)

    @ViewBuilder
    private func badgeLayer(_ size: CGSize) -> some View {
        if let badge = ix.badge, let f = ix.liveFrame ?? (ix.cropItemID != nil ? ix.cropWindow : nil) {
            let r = scaled(f, size)
            Text(badge)
                .font(.uiCaption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous))
                .foregroundStyle(.white)
                .fixedSize()
                .position(x: r.midX, y: min(r.maxY + 18, size.height - 10))
                .allowsHitTesting(false)
        }
    }

    // MARK: 키보드

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            if ix.cropItemID != nil { exitCrop(commit: false) } else { store.selectedItemID = nil }
            return .handled
        }
        if press.key == .return {
            if ix.cropItemID != nil { exitCrop(commit: true); return .handled }
            if let item = store.selectedItem { enterCrop(item); return .handled }
            return .ignored
        }
        if press.characters == "R" && press.modifiers.contains(.shift) { showRulers.toggle(); return .handled }
        if press.modifiers.contains(.command), editable, ix.cropItemID == nil {
            let item = store.selectedItem
            let option = press.modifiers.contains(.option)
            switch String(press.key.character).lowercased() {
            case "d": if let item { store.duplicateItem(item.id) }; return .handled
            case "c": if let item { store.copyItem(item.id) }; return .handled
            case "v": store.pasteItem(); return .handled
            case "]": if let item { store.reorder(item.id, option ? .front : .forward) }; return .handled
            case "[": if let item { store.reorder(item.id, option ? .back : .backward) }; return .handled
            default: break
            }
        }
        guard editable, ix.cropItemID == nil, let item = store.selectedItem, !item.isLocked else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .leftArrow: store.nudge(item.id, dxPixels: -step, dyPixels: 0)
        case .rightArrow: store.nudge(item.id, dxPixels: step, dyPixels: 0)
        case .upArrow: store.nudge(item.id, dxPixels: 0, dyPixels: -step)
        case .downArrow: store.nudge(item.id, dxPixels: 0, dyPixels: step)
        case .delete, .deleteForward: store.removeItem(item.id)
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - 그리기 부품

/// Canva 스타일: 모서리는 흰 원, 옆은 흰 알약
struct CanvasHandleView: View {
    let handle: CanvasHandle
    var body: some View {
        ZStack {
            Color.clear.frame(width: 22, height: 22)
            if handle.isCorner {
                Circle().fill(.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            } else {
                Capsule().fill(.white)
                    .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: handle.isVerticalSide ? 6 : 20, height: handle.isVerticalSide ? 20 : 6)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 자르기 모드의 이미지 모서리 손잡이 (흰 원)
struct ImageScaleHandleView: View {
    var body: some View {
        ZStack {
            Color.clear.frame(width: 24, height: 24)
            Circle().fill(.white)
                .overlay(Circle().stroke(CanvasStyle.selection, lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
        }
        .contentShape(Circle())
    }
}

/// 회전 손잡이: 흰 원 안의 ↻ (Canva와 같은 모양)
struct RotateHandleView: View {
    var body: some View {
        ZStack {
            Color.clear.frame(width: 28, height: 28)
            Circle().fill(.white)
                .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CanvasStyle.selection)
        }
        .contentShape(Circle())
    }
}

/// 자르기 모드: 모서리는 ㄱ자 굵은 선, 옆은 짧은 막대
struct CropHandleView: View {
    let handle: CanvasHandle
    var body: some View {
        ZStack {
            Color.clear.frame(width: 26, height: 26)
            if handle.isCorner {
                Path { p in
                    let l: CGFloat = 12
                    let sx: CGFloat = handle.movesLeft ? 1 : -1, sy: CGFloat = handle.movesTop ? 1 : -1
                    p.move(to: CGPoint(x: 13 + sx * l, y: 13)); p.addLine(to: CGPoint(x: 13, y: 13)); p.addLine(to: CGPoint(x: 13, y: 13 + sy * l))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.4), radius: 1)
            } else {
                Capsule().fill(.white)
                    .frame(width: handle.isVerticalSide ? 4 : 18, height: handle.isVerticalSide ? 18 : 4)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SmartGuideOverlay: View {
    let lines: [GuideLine]
    let gaps: [GapMark]
    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            Canvas { ctx, _ in
                for l in lines {
                    var p = Path()
                    if l.axis == .vertical {
                        p.move(to: CGPoint(x: l.position * s.width, y: l.from * s.height))
                        p.addLine(to: CGPoint(x: l.position * s.width, y: l.to * s.height))
                    } else {
                        p.move(to: CGPoint(x: l.from * s.width, y: l.position * s.height))
                        p.addLine(to: CGPoint(x: l.to * s.width, y: l.position * s.height))
                    }
                    ctx.stroke(p, with: .color(CanvasStyle.smartGuide), lineWidth: 1)
                }
                for g in gaps {
                    let a: CGPoint, b: CGPoint
                    if g.alongX { a = CGPoint(x: g.start * s.width, y: g.cross * s.height); b = CGPoint(x: g.end * s.width, y: g.cross * s.height) }
                    else { a = CGPoint(x: g.cross * s.width, y: g.start * s.height); b = CGPoint(x: g.cross * s.width, y: g.end * s.height) }
                    var p = Path(); p.move(to: a); p.addLine(to: b)
                    // 양 끝 짧은 막대
                    let cap: CGFloat = 4
                    for e in [a, b] {
                        if g.alongX { p.move(to: CGPoint(x: e.x, y: e.y - cap)); p.addLine(to: CGPoint(x: e.x, y: e.y + cap)) }
                        else { p.move(to: CGPoint(x: e.x - cap, y: e.y)); p.addLine(to: CGPoint(x: e.x + cap, y: e.y)) }
                    }
                    ctx.stroke(p, with: .color(CanvasStyle.smartGuide), style: StrokeStyle(lineWidth: 1, dash: g.equal ? [] : [3, 2]))
                    let label = Text((g.equal ? "= " : "") + "\(g.pixels)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    let resolved = ctx.resolve(label)
                    let ts = resolved.measure(in: CGSize(width: 200, height: 40))
                    let box = CGRect(x: mid.x - ts.width / 2 - 5, y: mid.y - ts.height / 2 - 2, width: ts.width + 10, height: ts.height + 4)
                    ctx.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(CanvasStyle.smartGuide))
                    ctx.draw(resolved, at: mid, anchor: .center)
                }
            }
        }
    }
}

/// 방송 안전 영역: 바깥 점선 93%(동작 안전), 안쪽 점선 90%(자막 안전)
struct SafeAreaOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            ForEach([0.93, 0.90], id: \.self) { k in
                Rectangle()
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(width: s.width * k, height: s.height * k)
                    .position(x: s.width / 2, y: s.height / 2)
            }
        }
    }
}

struct RulerCorner: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CanvasStyle.rulerBackground
            Text("px").font(.system(size: 8)).foregroundStyle(CanvasStyle.rulerText).padding(2)
        }
    }
}

/// 출력 픽셀(1280×720) 눈금. highlight = 선택한 소스의 범위, guides = 가이드 위치 표시
struct RulerView: View {
    let alongX: Bool
    var highlight: ClosedRange<CGFloat>?
    var guides: [CGFloat] = []

    var body: some View {
        Canvas { ctx, size in
            let length = alongX ? size.width : size.height
            let thick = alongX ? size.height : size.width
            let total = alongX ? OutputCanvas.width : OutputCanvas.height
            guard length > 0 else { return }
            let perPx = length / total

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(CanvasStyle.rulerBackground))
            if let h = highlight {
                let a = h.lowerBound * length, b = h.upperBound * length
                let r = alongX ? CGRect(x: a, y: 0, width: b - a, height: thick) : CGRect(x: 0, y: a, width: thick, height: b - a)
                ctx.fill(Path(r), with: .color(CanvasStyle.selection.opacity(0.35)))
            }

            let minors: [CGFloat] = [5, 10, 20, 25, 50, 100, 200]
            let minor = minors.first { $0 * perPx >= 5 } ?? 200
            let majors: [CGFloat] = [50, 100, 200, 250, 500]
            let major = majors.first { $0 * perPx >= 46 && $0.truncatingRemainder(dividingBy: minor) == 0 } ?? 500

            var ticks = Path()
            var v: CGFloat = 0
            while v <= total + 0.5 {
                let p = (v * perPx).rounded() + 0.5
                let isMajor = v.truncatingRemainder(dividingBy: major) == 0
                let isMid = !isMajor && v.truncatingRemainder(dividingBy: major / 2) == 0
                let len = thick * (isMajor ? 0.75 : isMid ? 0.45 : 0.25)
                if alongX { ticks.move(to: CGPoint(x: p, y: thick)); ticks.addLine(to: CGPoint(x: p, y: thick - len)) }
                else { ticks.move(to: CGPoint(x: thick, y: p)); ticks.addLine(to: CGPoint(x: thick - len, y: p)) }
                if isMajor && v > 0 && v < total {
                    let label = ctx.resolve(Text("\(Int(v))").font(.system(size: 8).monospacedDigit()).foregroundColor(CanvasStyle.rulerText))
                    if alongX { ctx.draw(label, at: CGPoint(x: p + 2, y: 1), anchor: .topLeading) }
                    else {
                        var c = ctx
                        c.translateBy(x: 1, y: p - 2)
                        c.rotate(by: .degrees(-90))
                        c.draw(label, at: .zero, anchor: .topLeading)
                    }
                }
                v += minor
            }
            ctx.stroke(ticks, with: .color(CanvasStyle.rulerTick), lineWidth: 1)

            for g in guides {
                let p = g * length
                var m = Path()
                if alongX { m.move(to: CGPoint(x: p - 4, y: thick)); m.addLine(to: CGPoint(x: p + 4, y: thick)); m.addLine(to: CGPoint(x: p, y: thick - 5)) }
                else { m.move(to: CGPoint(x: thick, y: p - 4)); m.addLine(to: CGPoint(x: thick, y: p + 4)); m.addLine(to: CGPoint(x: thick - 5, y: p)) }
                m.closeSubpath()
                ctx.fill(m, with: .color(CanvasStyle.userGuide))
            }

            var edge = Path()
            if alongX { edge.move(to: CGPoint(x: 0, y: thick - 0.5)); edge.addLine(to: CGPoint(x: length, y: thick - 0.5)) }
            else { edge.move(to: CGPoint(x: thick - 0.5, y: 0)); edge.addLine(to: CGPoint(x: thick - 0.5, y: length)) }
            ctx.stroke(edge, with: .color(Color(white: 0.3)), lineWidth: 1)
        }
    }
}

/// 엔진이 그리지 못한 소스 자리: 주황 점선 상자와 이유
struct MissingSourceView: View {
    let name: String
    let reason: String
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.orange.opacity(0.12)
                Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                if g.size.width > 120 && g.size.height > 50 {
                    VStack(spacing: 4) {
                        Label(name, systemImage: "exclamationmark.triangle.fill").font(.uiCaption.weight(.semibold))
                        if g.size.height > 80 {
                            Text(reason).font(.uiCaption2).multilineTextAlignment(.center).lineLimit(3)
                        }
                    }
                    .foregroundStyle(.orange)
                    .padding(8)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
