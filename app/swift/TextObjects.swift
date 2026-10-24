// SPDX-License-Identifier: GPL-2.0-or-later
// 글자 오브젝트: 글자 크기에 딱 맞는 투명 PNG로 그려 장면에 놓는다 (캔버스에서 옮기고 키울 수 있다).
// 글꼴·크기·굵기·색·정렬·그림자·배경 상자를 바꾸면 같은 배율을 유지한 채 다시 그린다.
import SwiftUI
import AppKit
import CryptoKit

/// 글자 모양. 크기는 1080p 화면 기준 픽셀
struct TextObjectStyle: Codable, Hashable {
    var font: String = TextObjectStyle.defaultFont
    var size: Double = 72
    var bold: Bool = true
    var color: String = "FFFFFF"
    var align: String = "center"      // left · center · right
    var shadow: Bool = true
    var box: String? = nil            // 배경 상자 색 (nil = 없음)
    var boxOpacity: Double = 0.6

    static let defaultFont = "Apple SD Gothic Neo"
    /// 자주 쓰는 글꼴 (한글 지원 위주). 이 Mac에 있는 것만 보여 준다
    static let favorites = ["Apple SD Gothic Neo", "AppleMyungjo", "Nanum Gothic", "NanumMyeongjo", "Noto Sans KR", "Noto Serif KR",
                            "Pretendard", "Spoqa Han Sans Neo", "Helvetica Neue", "Avenir Next", "Times New Roman", "Georgia", "Didot"]
}

enum TextRenderer {
    private static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChurchOBS/text", isDirectory: true)

    private static var canvas: CGSize { VideoQuality.running.size }

    private static func attributes(_ style: TextObjectStyle) -> [NSAttributedString.Key: Any] {
        let scale = canvas.height / 1080
        let size = max(8, style.size) * scale
        let font = NSFontManager.shared.font(withFamily: style.font, traits: style.bold ? .boldFontMask : [], weight: style.bold ? 9 : 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.align == "left" ? .left : style.align == "right" ? .right : .center
        paragraph.lineHeightMultiple = 1.08
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph,
                                                    .foregroundColor: NSColor(Color(hex: style.color))]
        if style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.65)
            shadow.shadowBlurRadius = size * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.03)
            attrs[.shadow] = shadow
        }
        return attrs
    }

    private static func padding(_ style: TextObjectStyle) -> CGFloat {
        let size = max(8, style.size) * canvas.height / 1080
        return style.box != nil ? size * 0.45 : size * 0.18   // 상자 여백 · 그림자가 잘리지 않을 만큼
    }

    private static func textRect(_ text: String, _ style: TextObjectStyle) -> CGSize {
        let pad = padding(style)
        let limit = canvas.width * 0.94 - pad * 2
        let shown = text.isEmpty ? " " : text
        let r = (shown as NSString).boundingRect(with: NSSize(width: limit, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(style))
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// 그림 픽셀 크기 (장면 배치 계산용)
    static func pixelSize(text: String, style: TextObjectStyle) -> CGSize {
        let r = textRect(text, style), pad = padding(style)
        return CGSize(width: r.width + pad * 2, height: r.height + pad * 2)
    }

    /// 화면 비율로 바꾼 크기 (캔버스 = 1)
    static func normalizedSize(text: String, style: TextObjectStyle) -> CGSize {
        let px = pixelSize(text: text, style: style)
        return CGSize(width: px.width / canvas.width, height: px.height / canvas.height)
    }

    /// 글자 그림 파일. 같은 내용이면 다시 그리지 않는다
    static func render(sourceID: UUID, text: String, style: TextObjectStyle) -> URL? {
        let key = "\(text)|\(style.font)|\(style.size)|\(style.bold)|\(style.color)|\(style.align)|\(style.shadow)|\(style.box ?? "")|\(style.boxOpacity)|\(canvas.width)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent("\(sourceID.uuidString)-\(digest).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rect = textRect(text, style), pad = padding(style)
        let pw = Int(rect.width + pad * 2), ph = Int(rect.height + pad * 2)
        guard pw > 0, ph > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pw, height: ph)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: pw, height: ph).fill()
        if let box = style.box {
            NSColor(Color(hex: box)).withAlphaComponent(min(max(style.boxOpacity, 0), 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pw, height: ph), xRadius: pad * 0.5, yRadius: pad * 0.5).fill()
        }
        (text as NSString).draw(with: NSRect(x: pad, y: pad, width: rect.width, height: rect.height),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(style))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: file, options: .atomic)) != nil else { return nil }
        // 같은 소스의 예전 그림 정리
        let prefix = sourceID.uuidString + "-"
        if let old = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in old where name.hasPrefix(prefix) && name != file.lastPathComponent {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        return file
    }

    /// 단색 배경 그림 (예전 "불투명 배경" 문구를 배경 레이어로 나눌 때)
    static func solidBackground(_ hex: String) -> URL? {
        let file = folder.appendingPathComponent("background-\(hex).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let w = Int(canvas.width / 8), h = Int(canvas.height / 8)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(Color(hex: hex)).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}

/// 속성 패널: 글자 오브젝트 편집
struct TextObjectEditor: View {
    @Bindable var store: ShowStore
    let source: Source
    let value: String
    let style: TextObjectStyle
    @State private var draft = ""

    private var families: [String] {
        let all = NSFontManager.shared.availableFontFamilies
        let favs = TextObjectStyle.favorites.filter { all.contains($0) }
        return favs + all.filter { !favs.contains($0) }.sorted()
    }

    private func set(_ change: (inout TextObjectStyle) -> Void) {
        var s = style; change(&s); store.updateText(source.id, style: s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft)
                .font(.uiBody)
                .frame(minHeight: 80, maxHeight: 160)
                .onAppear { draft = value }
                .onChange(of: value) { if draft != value { draft = value } }
                .onChange(of: draft) { if draft != value { store.updateText(source.id, text: draft) } }
            Text("캔버스에서 글자를 끌어 옮기고, 모서리로 크기를 바꿀 수 있습니다.").font(.uiCaption2).foregroundStyle(.secondary)

            LabeledContent("글꼴") {
                Picker("글꼴", selection: Binding(get: { style.font }, set: { f in set { $0.font = f } })) {
                    ForEach(families, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 190)
            }
            HStack(spacing: 8) {
                Text("크기").font(.uiCaption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(get: { style.size }, set: { v in set { $0.size = v.rounded() } }), in: 16...240)
                Text("\(Int(style.size))").font(.uiCaption.monospacedDigit()).frame(width: 32)
            }
            HStack(spacing: 10) {
                Toggle("굵게", isOn: Binding(get: { style.bold }, set: { v in set { $0.bold = v } }))
                ColorPicker("글자색", selection: Binding(get: { Color(hex: style.color) }, set: { c in set { $0.color = c.hexString } }), supportsOpacity: false)
            }
            Picker("정렬", selection: Binding(get: { style.align }, set: { a in set { $0.align = a } })) {
                Image(systemName: "text.alignleft").tag("left")
                Image(systemName: "text.aligncenter").tag("center")
                Image(systemName: "text.alignright").tag("right")
            }
            .pickerStyle(.segmented)
            Toggle("그림자", isOn: Binding(get: { style.shadow }, set: { v in set { $0.shadow = v } }))
            HStack(spacing: 10) {
                Toggle("배경 상자", isOn: Binding(get: { style.box != nil }, set: { v in set { $0.box = v ? ($0.box ?? "000000") : nil } }))
                if let box = style.box {
                    ColorPicker("상자 색", selection: Binding(get: { Color(hex: box) }, set: { c in set { $0.box = c.hexString } }), supportsOpacity: false)
                        .labelsHidden()
                    Slider(value: Binding(get: { style.boxOpacity }, set: { v in set { $0.boxOpacity = v } }), in: 0.1...1)
                        .frame(width: 80)
                }
            }
        }
    }
}
