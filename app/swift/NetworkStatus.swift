// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import Darwin

/// 인터넷 상태: 이 Mac의 실제 업로드·다운로드 속도(1초마다), 인터넷 속도 측정(macOS networkQuality),
/// 방송 중에는 엔진이 알려 주는 송출 속도·끊긴 프레임·혼잡도
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var upMbps: Double = 0
    private(set) var downMbps: Double = 0
    private(set) var upHistory: [Double] = []          // 최근 60초
    private(set) var testing = false
    private(set) var tested: (up: Double, down: Double, at: Date)?
    private(set) var testError: String?

    /// 720p 3.5 Mbps + 소리 0.16 Mbps를 여유 있게 보내려면
    /// 720p 3.5Mbps → 5.5, 1080p 6Mbps → 9 (여유 포함)
    static var neededUpMbps: Double { VideoQuality.running.neededUpMbps }

    private var last: [String: (UInt64, UInt64)] = [:]
    private var lastAt: Date?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        let now = Date()
        var current: [String: (UInt64, UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let a = p {
            let ifa = a.pointee
            p = ifa.ifa_next
            // Wi-Fi·이더넷(en*)만. VPN(utun)은 같은 데이터를 두 번 셀 수 있어 뺀다
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
        }
        if let lastAt {
            let seconds = max(now.timeIntervalSince(lastAt), 0.2)
            var inBytes: UInt64 = 0, outBytes: UInt64 = 0
            for (name, value) in current {
                guard let prev = last[name] else { continue }
                // 카운터는 32비트라 4GB마다 0으로 돌아간다
                func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : a + (1 << 32) - b }
                inBytes += delta(value.0, prev.0); outBytes += delta(value.1, prev.1)
            }
            let down = Double(inBytes) * 8 / 1_000_000 / seconds
            let up = Double(outBytes) * 8 / 1_000_000 / seconds
            downMbps = downMbps * 0.5 + down * 0.5
            upMbps = upMbps * 0.5 + up * 0.5
            upHistory.append(upMbps)
            if upHistory.count > 60 { upHistory.removeFirst(upHistory.count - 60) }
        }
        last = current; lastAt = now
    }

    /// macOS 내장 속도 측정 (약 15~25초)
    func runSpeedTest() {
        guard !testing else { return }
        testing = true; testError = nil
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            process.arguments = ["-c", "-s"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            var result: (Double, Double)?
            var failure: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue,
                   let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue {
                    result = (ul / 1_000_000, dl / 1_000_000)
                } else { failure = L("측정 결과를 읽지 못했습니다.") }
            } catch { failure = L("이 Mac에서 속도 측정을 실행할 수 없습니다.") }
            let finalResult = result, finalFailure = failure
            await MainActor.run {
                let monitor = NetworkMonitor.shared
                monitor.testing = false
                if let r = finalResult { monitor.tested = (r.0, r.1, Date()) } else { monitor.testError = finalFailure }
            }
        }
    }
}

/// 방송 송출 상태 (엔진 값)
struct StreamHealth {
    var active = false, reconnecting = false
    var kbps: Double = 0, targetKbps: Double = 3660
    var dropped = 0, frames = 0
    var congestion: Double = 0

    init(_ state: [String: Any]?) {
        guard let s = state else { return }
        active = s["active"] as? Bool ?? false
        reconnecting = s["reconnecting"] as? Bool ?? false
        kbps = (s["kbps"] as? NSNumber)?.doubleValue ?? 0
        targetKbps = (s["targetKbps"] as? NSNumber)?.doubleValue ?? 3660
        dropped = (s["dropped"] as? NSNumber)?.intValue ?? 0
        frames = (s["frames"] as? NSNumber)?.intValue ?? 0
        congestion = (s["congestion"] as? NSNumber)?.doubleValue ?? 0
    }

    var droppedPercent: Double { frames > 0 ? Double(dropped) / Double(frames) * 100 : 0 }

    enum Level { case good, warn, bad }
    var level: Level {
        if reconnecting || droppedPercent > 5 { return .bad }
        if droppedPercent > 1 || congestion > 0.5 || (kbps > 0 && kbps < targetKbps * 0.7) { return .warn }
        return .good
    }
    var color: Color { level == .good ? ChurchStatus.ok : level == .warn ? .orange : .red }
    var summary: String {
        if reconnecting { return L("다시 연결 중") }
        switch level { case .good: return L("원활"); case .warn: return L("느려짐"); case .bad: return L("끊김 많음") }
    }
}

private func mbps(_ v: Double) -> String { v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v) }

/// 하단 막대의 작은 인터넷 표시. 누르면 자세히
struct NetworkPill: View {
    let stream: StreamHealth
    @State private var net = NetworkMonitor.shared
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                if stream.active {
                    HStack(spacing: 5) {
                        Circle().fill(stream.color).frame(width: 8, height: 8)
                        Text("송출 \(mbps(stream.kbps / 1000)) Mbps").font(.uiCaption.weight(.semibold).monospacedDigit())
                        if stream.dropped > 0 {
                            Text("끊김 \(String(format: "%.1f", stream.droppedPercent))%").font(.uiCaption.monospacedDigit()).foregroundStyle(stream.color)
                        }
                    }
                    Divider().frame(height: 14)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(ChurchBrand.blue)
                    Text(mbps(net.upMbps)).font(.uiCaption.monospacedDigit())
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Text(mbps(net.downMbps)).font(.uiCaption.monospacedDigit())
                    Text("Mbps").font(.uiCaption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .churchGlass(ChurchShape.button, interactive: true)
        }
        .buttonStyle(.plain)
        .help("인터넷 상태 자세히 보기")
        .popover(isPresented: $open, arrowEdge: .top) { NetworkDetail(stream: stream).frame(width: 360).padding(18) }
        .onAppear { net.start() }
    }
}

/// 인터넷 상태 자세히: 송출 상태 · 지금 속도 · 최근 60초 업로드 · 속도 측정
struct NetworkDetail: View {
    let stream: StreamHealth
    @State private var net = NetworkMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("인터넷 상태").font(.uiHeadline)

            if stream.active {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L(stream.summary), systemImage: "dot.radiowaves.left.and.right").foregroundStyle(stream.color).font(.uiCallout.weight(.semibold))
                        Spacer()
                        Text("\(mbps(stream.kbps / 1000)) / \(mbps(stream.targetKbps / 1000)) Mbps").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(stream.kbps / max(stream.targetKbps, 1), 1)).tint(stream.color)
                    HStack {
                        stat("끊긴 프레임", "\(stream.dropped) (\(String(format: "%.1f", stream.droppedPercent))%)")
                        Spacer()
                        stat("혼잡도", "\(Int(stream.congestion * 100))%")
                    }
                }
                .padding(12)
                .background(stream.color.opacity(0.10), in: RoundedRectangle(cornerRadius: ChurchShape.floating, style: .continuous))
            }

            HStack(spacing: 18) {
                speed("업로드", net.upMbps, "arrow.up", ChurchBrand.blue)
                speed("다운로드", net.downMbps, "arrow.down", .secondary)
            }
            UploadSparkline(values: net.upHistory).frame(height: 44)
            Text("최근 60초 업로드 · 이 Mac 전체 사용량").font(.uiCaption2).foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("인터넷 속도 측정").font(.uiCallout.weight(.semibold))
                    Spacer()
                    if net.testing { ProgressView().controlSize(.small) }
                    Button(net.testing ? L("측정 중…") : net.tested == nil ? L("측정") : L("다시 측정")) { net.runSpeedTest() }
                        .disabled(net.testing || stream.active)
                        .help(stream.active ? L("방송 중에는 측정하면 송출이 끊길 수 있어 막아 두었습니다") : L("약 20초 걸립니다"))
                }
                if let t = net.tested {
                    let ok = t.up >= NetworkMonitor.neededUpMbps
                    HStack(spacing: 16) {
                        stat("업로드 최대", "\(mbps(t.up)) Mbps")
                        stat("다운로드 최대", "\(mbps(t.down)) Mbps")
                    }
                    Label(ok ? "\(VideoQuality.running.title) 방송에 충분합니다 (필요 \(mbps(NetworkMonitor.neededUpMbps)) Mbps 이상)"
                             : "업로드가 부족합니다. 유선 랜을 쓰거나 다른 기기의 인터넷 사용을 줄이세요 (필요 \(mbps(NetworkMonitor.neededUpMbps)) Mbps)",
                          systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.uiCaption).foregroundStyle(ok ? ChurchStatus.ok : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let e = net.testError {
                    Text(e).font(.uiCaption).foregroundStyle(.orange)
                } else {
                    Text("방송 전에 한 번 재 보세요. 업로드가 \(mbps(NetworkMonitor.neededUpMbps)) Mbps 이상이면 안정적입니다.").font(.uiCaption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { net.start() }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L(title)).font(.uiCaption2).foregroundStyle(.secondary)
            Text(value).font(.uiCallout.weight(.semibold).monospacedDigit())
        }
    }

    private func speed(_ title: String, _ value: Double, _ symbol: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text(mbps(value)).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            VStack(alignment: .leading, spacing: 0) {
                Text("Mbps").font(.uiCaption2).foregroundStyle(.secondary)
                Text(L(title)).font(.uiCaption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 최근 업로드 속도 선 그래프
struct UploadSparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            let step = geo.size.width / CGFloat(max(59, 1))
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width - CGFloat(values.count - 1 - i) * step,
                        y: geo.size.height - CGFloat(v / maxValue) * (geo.size.height - 4) - 2)
            }
            ZStack {
                RoundedRectangle(cornerRadius: ChurchShape.badge, style: .continuous).fill(Color.secondary.opacity(0.08))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [ChurchBrand.blue.opacity(0.35), ChurchBrand.blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(points) }
                        .stroke(ChurchBrand.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("최근 업로드 속도 그래프")
    }
}

/// 준비 화면 YouTube 카드 안: 지금 인터넷 속도 + 측정 결과 한 줄
struct InternetCheckRow: View {
    @State private var net = NetworkMonitor.shared
    @State private var open = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            if let t = net.tested {
                let ok = t.up >= NetworkMonitor.neededUpMbps
                Text("업로드 \(mbps(t.up)) Mbps").font(.uiCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ok ? ChurchStatus.ok : .orange)
                Text(ok ? L("방송에 충분") : L("부족할 수 있음")).font(.uiCaption).foregroundStyle(.secondary)
            } else {
                Text("↑ \(mbps(net.upMbps)) ↓ \(mbps(net.downMbps)) Mbps").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(net.testing ? L("측정 중…") : L("속도 측정")) { open = true; net.runSpeedTest() }
                .disabled(net.testing)
                .popover(isPresented: $open, arrowEdge: .trailing) { NetworkDetail(stream: StreamHealth(nil)).frame(width: 360).padding(18) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ChurchShape.button, style: .continuous))
        .onAppear { net.start() }
    }
}
