// MediaGraphicsPanels.swift
// Church OBS — 장면 편집 왼쪽 패널의 "미디어"(사진·영상·소리 보관함)와 "그래픽"(아이콘 팩) 탭
//
// 미디어: Finder에서 끌어 놓거나 가져오기 → 썸네일 보관함 → 클릭하면 장면에 추가, 캔버스로 끌면 그 자리에 추가
// 그래픽: Iconify 공개 API로 아이콘 팩(Lucide·Material Symbols·Phosphor·Tabler·Heroicons·Remix·MDI)을
//         검색해 색을 고르고 PNG로 만들어 장면에 넣는다. 받은 아이콘은 이 Mac에 저장해 다음에는 인터넷 없이 쓴다.

import SwiftUI
import AppKit
import QuickLookThumbnailing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 파일 종류

enum MediaType: String {
    case image, video, audio, unsupported

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "flac", "ogg"]

    static func of(_ url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return .unsupported
    }

    /// 사진·영상의 픽셀 크기 (장면에 넣을 때 비율을 맞추려고)
    static func pixelSize(_ url: URL) async -> CGSize? {
        switch of(url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        case .video:
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let loaded = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let r = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
            return CGSize(width: abs(r.width), height: abs(r.height))
        default:
            return nil
        }
    }
}

// MARK: - 미디어 보관함

@MainActor
@Observable
final class MediaLibrary {
    static let shared = MediaLibrary()

    struct Entry: Identifiable, Codable, Hashable {
        var id: String { path }
        let path: String
        var addedAt: Date
        var url: URL { URL(fileURLWithPath: path) }
        var type: MediaType { MediaType.of(url) }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private(set) var entries: [Entry] = []
    var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    private static let key = "media.library.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    /// 지원하는 파일만 맨 앞에 넣는다 (이미 있으면 앞으로). 넣은 파일 URL 반환
    @discardableResult
    func add(_ urls: [URL]) -> [URL] {
        var accepted: [URL] = []
        for url in urls where url.isFileURL && MediaType.of(url) != .unsupported {
            let path = url.standardizedFileURL.path
            entries.removeAll { $0.path == path }
            entries.insert(Entry(path: path, addedAt: Date()), at: 0)
            accepted.append(url)
        }
        if entries.count > 300 { entries = Array(entries.prefix(300)) }
        save()
        return accepted
    }

    func remove(_ path: String) {
        entries.removeAll { $0.path == path }
        thumbnails[path] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// 썸네일은 처음 보일 때 한 번만 만든다 (Quick Look)
    func requestThumbnail(_ entry: Entry) {
        guard thumbnails[entry.path] == nil, !requested.contains(entry.path), entry.exists else { return }
        requested.insert(entry.path)
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: 180, height: 120),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let image = NSImage(cgImage: cg, size: .zero)
            Task { @MainActor [weak self] in self?.thumbnails[entry.path] = image }
        }
    }

    func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .audio]
        return panel.runModal() == .OK ? add(panel.urls) : []
    }
}

// MARK: - 아이콘 팩

struct IconPack: Identifiable, Hashable {
    let id: String          // Iconify prefix
    let name: String
    let note: String

    static let all: [IconPack] = [
        IconPack(id: "lucide", name: "Lucide", note: L("Claude·shadcn 계열의 깔끔한 선 아이콘")),
        IconPack(id: "material-symbols", name: "Material Symbols", note: L("Google·Gemini 스타일")),
        IconPack(id: "ph", name: "Phosphor", note: L("굵기·채움 6가지 스타일")),
        IconPack(id: "tabler", name: "Tabler", note: L("선 아이콘 5천여 개")),
        IconPack(id: "heroicons", name: "Heroicons", note: L("Tailwind 팀의 기본 아이콘")),
        IconPack(id: "ri", name: "Remix Icon", note: L("선·면 아이콘")),
        IconPack(id: "mdi", name: "Material Design", note: L("교회·십자가 등 종류가 가장 많음")),
    ]
}

struct IconRef: Hashable, Identifiable {
    let prefix: String
    let name: String
    var id: String { "\(prefix):\(name)" }

    init(prefix: String, name: String) { self.prefix = prefix; self.name = name }
    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        prefix = parts[0]; name = parts[1]
    }
    /// 캔버스로 끌어 놓을 때 쓰는 주소: churchobs-icon://lucide/church?color=FFFFFF
    func dragURL(color: String) -> URL {
        URL(string: "churchobs-icon://\(prefix)/\(name)?color=\(color.replacingOccurrences(of: "#", with: ""))")!
    }
    init?(dragURL url: URL) {
        guard url.scheme == "churchobs-icon", let host = url.host else { return nil }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return nil }
        prefix = host; self.name = name
    }
}

@MainActor
@Observable
final class IconLibrary {
    static let shared = IconLibrary()

    /// 미리보기 (밝은 회색으로 칠한 SVG)
    var previews: [String: NSImage] = [:]
    var loading = false
    var error: String?

    private struct Glyph: Codable { var body: String; var width: Double; var height: Double }
    @ObservationIgnored private var glyphs: [String: Glyph] = [:]
    @ObservationIgnored private var listCache: [String: [String]] = [:]
    @ObservationIgnored private var pending: Set<IconRef> = []
    @ObservationIgnored private var flushScheduled = false
    private let api = "https://api.iconify.design"
    private let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChurchOBS/icons", isDirectory: true)
    private let graphicsFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChurchOBS/graphics", isDirectory: true)

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("glyphs.json")),
           let saved = try? JSONDecoder().decode([String: Glyph].self, from: data) { glyphs = saved }
    }

    // MARK: 목록·검색

    /// 팩 전체 이름 (처음 한 번 받아 이 Mac에 저장)
    func names(in pack: String) async -> [String] {
        if let cached = listCache[pack] { return cached }
        let file = folder.appendingPathComponent("\(pack)-names.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String].self, from: data) {
            listCache[pack] = saved; return saved
        }
        loading = true; defer { loading = false }
        guard let object = await getJSON("\(api)/collection?prefix=\(pack)") else { return [] }
        var names = object["uncategorized"] as? [String] ?? []
        if let categories = object["categories"] as? [String: [String]] {
            for key in categories.keys.sorted() { names += categories[key] ?? [] }
        }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        listCache[pack] = names
        if let data = try? JSONEncoder().encode(names) { try? data.write(to: file, options: .atomic) }
        return names
    }

    func search(_ query: String, in pack: String) async -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        loading = true; defer { loading = false }
        guard let object = await getJSON("\(api)/search?query=\(encoded)&prefix=\(pack)&limit=200") else { return [] }
        return (object["icons"] as? [String] ?? []).compactMap { IconRef(id: $0)?.name }
    }

    // MARK: 미리보기 (보이는 것만 묶어서 받기)

    func request(_ ref: IconRef) {
        guard previews[ref.id] == nil else { return }
        if let glyph = glyphs[ref.id] { previews[ref.id] = image(glyph, color: "#D7DCE2"); return }
        pending.insert(ref)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            await self?.flush()
        }
    }

    private func flush() async {
        flushScheduled = false
        let batch = pending; pending.removeAll()
        let byPack = Dictionary(grouping: batch, by: \.prefix)
        for (pack, refs) in byPack {
            for chunk in stride(from: 0, to: refs.count, by: 100).map({ Array(refs[$0..<min($0 + 100, refs.count)]) }) {
                await fetchGlyphs(pack: pack, names: chunk.map(\.name))
                for ref in chunk { if let g = glyphs[ref.id] { previews[ref.id] = image(g, color: "#D7DCE2") } }
            }
        }
        saveGlyphs()
    }

    private func fetchGlyphs(pack: String, names: [String]) async {
        let list = names.joined(separator: ",")
        guard let encoded = list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let object = await getJSON("\(api)/\(pack).json?icons=\(encoded)") else { return }
        let defaultW = (object["width"] as? NSNumber)?.doubleValue ?? 16
        let defaultH = (object["height"] as? NSNumber)?.doubleValue ?? 16
        let icons = object["icons"] as? [String: [String: Any]] ?? [:]
        for (name, value) in icons {
            guard let body = value["body"] as? String else { continue }
            glyphs["\(pack):\(name)"] = Glyph(body: body,
                                              width: (value["width"] as? NSNumber)?.doubleValue ?? defaultW,
                                              height: (value["height"] as? NSNumber)?.doubleValue ?? defaultH)
        }
        // 별칭(alias)은 원래 아이콘을 그대로 쓴다
        if let aliases = object["aliases"] as? [String: [String: Any]] {
            for (alias, value) in aliases {
                if let parent = value["parent"] as? String, let g = glyphs["\(pack):\(parent)"] { glyphs["\(pack):\(alias)"] = g }
            }
        }
    }

    private func saveGlyphs() {
        if let data = try? JSONEncoder().encode(glyphs) {
            try? data.write(to: folder.appendingPathComponent("glyphs.json"), options: .atomic)
        }
    }

    // MARK: 그리기

    private func svg(_ g: Glyph, color: String) -> String {
        let body = g.body.replacingOccurrences(of: "currentColor", with: color)
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(g.width) \(g.height)\" width=\"\(g.width)\" height=\"\(g.height)\">\(body)</svg>"
    }

    private func image(_ g: Glyph, color: String) -> NSImage? {
        NSImage(data: Data(svg(g, color: color).utf8))
    }

    /// 장면에 넣을 PNG (긴 변 512px). 같은 아이콘·색이면 다시 만들지 않는다
    func rasterize(_ ref: IconRef, colorHex: String) async throws -> (url: URL, pixelSize: CGSize) {
        let hex = "#" + colorHex.replacingOccurrences(of: "#", with: "").uppercased()
        if glyphs[ref.id] == nil { await fetchGlyphs(pack: ref.prefix, names: [ref.name]); saveGlyphs() }
        guard let g = glyphs[ref.id], let image = image(g, color: hex) else {
            throw CloudError(message: L("아이콘을 받지 못했습니다. 인터넷 연결을 확인하세요."))
        }
        let longest: Double = 512
        let scale = longest / max(g.width, g.height)
        let pw = Int((g.width * scale).rounded()), ph = Int((g.height * scale).rounded())
        try FileManager.default.createDirectory(at: graphicsFolder, withIntermediateDirectories: true)
        let file = graphicsFolder.appendingPathComponent("\(ref.prefix)-\(ref.name)-\(hex.dropFirst()).png")
        if FileManager.default.fileExists(atPath: file.path) { return (file, CGSize(width: pw, height: ph)) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw CloudError(message: L("아이콘 그림을 만들지 못했습니다.")) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CloudError(message: L("아이콘 그림을 만들지 못했습니다.")) }
        try png.write(to: file, options: .atomic)
        return (file, CGSize(width: pw, height: ph))
    }

    private func getJSON(_ text: String) async -> [String: Any]? {
        guard let url = URL(string: text) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { error = L("아이콘 서버 응답이 올바르지 않습니다."); return nil }
            error = nil
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            self.error = L("아이콘을 받으려면 인터넷 연결이 필요합니다.")
            return nil
        }
    }
}

// MARK: - 장면에 넣기 (패널 클릭·캔버스 끌어 놓기 공통)

@MainActor
enum StudioInsert {
    static func media(_ url: URL, into store: ShowStore, at point: CGPoint?) async {
        let type = MediaType.of(url)
        guard type != .unsupported else { store.lastError = "지원하지 않는 파일입니다: \(url.lastPathComponent)"; return }
        MediaLibrary.shared.add([url])
        let size = await MediaType.pixelSize(url)
        store.addMedia(url, type: type, pixelSize: size, at: point)
    }

    static func graphic(_ ref: IconRef, colorHex: String, into store: ShowStore, at point: CGPoint?) async {
        do {
            let result = try await IconLibrary.shared.rasterize(ref, colorHex: colorHex)
            store.addGraphic(icon: ref.id, color: colorHex, path: result.url.path, pixelSize: result.pixelSize, at: point)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    /// 캔버스에 떨어진 것들 (Finder 파일, 미디어 썸네일, 아이콘)
    static func drop(_ urls: [URL], into store: ShowStore, at point: CGPoint, color: String) {
        Task { @MainActor in
            for (i, url) in urls.enumerated() {
                let p = CGPoint(x: min(point.x + CGFloat(i) * 0.03, 0.95), y: min(point.y + CGFloat(i) * 0.03, 0.95))
                if let ref = IconRef(dragURL: url) {
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let c = items.first(where: { $0.name == "color" })?.value ?? color
                    await graphic(ref, colorHex: c, into: store, at: p)
                } else if url.isFileURL {
                    await media(url, into: store, at: p)
                }
            }
        }
    }
}

// MARK: - 미디어 패널

struct MediaPanel: View {
    @Bindable var store: ShowStore
    @State private var library = MediaLibrary.shared
    @State private var filter: MediaType? = nil
    @State private var targeted = false
    @AppStorage("media.tab") private var tab = 0

    private var shown: [MediaLibrary.Entry] {
        library.entries.filter { filter == nil || $0.type == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("내 파일").tag(0)
                Text("유튜브").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if tab == 1 { YouTubeAddPanel(store: store) } else { localFiles }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var localFiles: some View {
        let empty = library.entries.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            Button {
                let urls = library.choose()
                for url in urls { Task { await StudioInsert.media(url, into: store, at: nil) } }
            } label: {
                VStack(spacing: empty ? 8 : 4) {
                    Image(systemName: "square.and.arrow.down").font(empty ? .uiTitle2 : .uiTitle3)
                    Text(empty ? "사진·영상·음악 파일을\n여기로 끌어 놓으세요" : L("파일 끌어 놓기 · 눌러서 가져오기"))
                        .font(empty ? .uiCallout.weight(.medium) : .uiCaption)
                        .multilineTextAlignment(.center)
                    if empty { Text("또는 눌러서 파일 고르기").font(.uiCaption).foregroundStyle(.tertiary) }
                }
                .frame(maxWidth: .infinity, minHeight: empty ? 150 : 64)
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .background((targeted ? Color.accentColor.opacity(0.08) : Color.clear),
                            in: RoundedRectangle(cornerRadius: ChurchShape.floating, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ChurchShape.floating, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                let accepted = library.add(urls)
                return !accepted.isEmpty
            } isTargeted: { targeted = $0 }

            if !empty {
                HStack(spacing: 6) {
                    FilterChip(title: L("전체"), count: library.entries.count, selected: filter == nil) { filter = nil }
                    ForEach([MediaType.image, .video, .audio], id: \.self) { type in
                        let n = library.entries.filter { $0.type == type }.count
                        if n > 0 {
                            FilterChip(title: type == .image ? L("사진") : type == .video ? L("영상") : L("소리"), count: n,
                                       selected: filter == type) { filter = type }
                        }
                    }
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(shown) { entry in
                        MediaThumb(entry: entry, image: library.thumbnails[entry.path])
                            .onAppear { library.requestThumbnail(entry) }
                            .onTapGesture { Task { await StudioInsert.media(entry.url, into: store, at: nil) } }
                            .draggable(entry.url) { MediaThumb(entry: entry, image: library.thumbnails[entry.path]).frame(width: 96) }
                            .contextMenu {
                                Button("장면에 추가") { Task { await StudioInsert.media(entry.url, into: store, at: nil) } }
                                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                                Divider()
                                Button("목록에서 빼기") { library.remove(entry.path) }
                            }
                            .help("클릭: 장면에 추가 · 캔버스로 끌면 그 자리에 추가")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct MediaThumb: View {
    let entry: MediaLibrary.Entry
    let image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color.black.opacity(0.35)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.type == .audio ? "music.note" : entry.type == .video ? "film" : "photo")
                        .font(.uiTitle3).foregroundStyle(.secondary)
                }
                if entry.type == .video {
                    Image(systemName: "play.circle.fill").font(.uiTitle3).foregroundStyle(.white.opacity(0.85)).shadow(radius: 2)
                }
                if !entry.exists {
                    Color.black.opacity(0.6)
                    Label("파일 없음", systemImage: "exclamationmark.triangle.fill").font(.uiCaption2).foregroundStyle(.orange)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: ChurchShape.badge))
            Text(entry.url.lastPathComponent).font(.uiCaption2).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 그래픽 패널

struct GraphicsPanel: View {
    @Bindable var store: ShowStore
    @State private var icons = IconLibrary.shared
    @AppStorage("graphics.pack") private var pack = "lucide"
    @AppStorage("graphics.color") private var colorHex = "FFFFFF"
    @State private var query = ""
    @State private var names: [String] = []
    @State private var limit = 240
    @State private var searchTask: Task<Void, Never>?

    private struct Chip: Hashable { let title: String; let query: String }
    private let chips: [Chip] = [Chip(title: L("교회"), query: "church"), Chip(title: L("십자가"), query: "cross"),
                                 Chip(title: L("성경"), query: "bible"), Chip(title: L("기도"), query: "pray"),
                                 Chip(title: L("하트"), query: "heart"), Chip(title: L("음악"), query: "music"),
                                 Chip(title: L("별"), query: "star"), Chip(title: L("화살표"), query: "arrow")]
    private let swatches = ["FFFFFF", "111111", "F2B632", "E84A3C", "2F6BE6", "30C35A"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("아이콘 팩", selection: $pack) {
                ForEach(IconPack.all) { p in Text(p.name).tag(p.id) }
            }
            .labelsHidden()
            if let p = IconPack.all.first(where: { $0.id == pack }) {
                Text(p.note).font(.uiCaption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("영어로 검색 (church, cross…)", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { load() }
                if !query.isEmpty { Button { query = ""; load() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.self) { chip in
                        FilterChip(title: chip.title, selected: query == chip.query) { query = chip.query; load() }
                    }
                }
            }

            HStack(spacing: 6) {
                Text("색").font(.uiCaption).foregroundStyle(.secondary)
                ForEach(swatches, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(colorHex == hex ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: colorHex == hex ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("색 \(hex)")
                }
                ColorPicker("", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
            }

            if let error = icons.error { Text(error).font(.uiCaption2).foregroundStyle(.orange) }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(Array(names.prefix(limit)), id: \.self) { name in
                        let ref = IconRef(prefix: pack, name: name)
                        IconCell(image: icons.previews[ref.id])
                            .onAppear { icons.request(ref) }
                            .onTapGesture { Task { await StudioInsert.graphic(ref, colorHex: colorHex, into: store, at: nil) } }
                            .draggable(ref.dragURL(color: colorHex)) { IconCell(image: icons.previews[ref.id]).frame(width: 44, height: 44) }
                            .help("\(name) · 클릭: 장면에 추가 · 캔버스로 끌면 그 자리에")
                    }
                }
                if names.count > limit {
                    Button("더 보기 (\(names.count - limit)개 더)") { limit += 240 }.buttonStyle(.link).padding(.vertical, 6)
                }
                if names.isEmpty && !icons.loading {
                    Text(query.isEmpty ? L("아이콘을 불러오는 중이거나 인터넷 연결이 필요합니다.") : L("검색 결과가 없습니다. 다른 팩이나 영어 단어로 찾아보세요."))
                        .font(.uiCaption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .overlay(alignment: .top) { if icons.loading { ProgressView().controlSize(.regular).padding(6) } }

            Text("아이콘: Iconify 제공 · Lucide(ISC) Material·Remix·MDI(Apache-2.0) Phosphor·Tabler·Heroicons(MIT)")
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
        }
        .onAppear { if names.isEmpty { load() } }
        .onChange(of: pack) { load() }
    }

    private func load() {
        searchTask?.cancel()
        limit = 240
        let q = query, p = pack
        searchTask = Task { @MainActor in
            let result = q.isEmpty ? await icons.names(in: p) : await icons.search(q, in: p)
            if !Task.isCancelled { names = result }
        }
    }
}

private struct IconCell: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ChurchShape.badge).fill(Color.secondary.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(9)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

// MARK: - 색 도우미

extension Color {
    init(hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
