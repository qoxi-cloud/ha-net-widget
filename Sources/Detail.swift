import Combine
import SwiftUI

enum DetailKind: Hashable {
    case metric(String)
    case rates
    case status
}

/// what a click on the widget opens: a tile's history, the throughput, or the status timeline
struct DetailTarget: Hashable {
    let row: String
    let kind: DetailKind
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1h", day = "24h", week = "7d"

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86400
        case .week: 7 * 86400
        }
    }
    /// long-term statistics bucket; the last hour is drawn from raw states
    var period: (name: String, seconds: TimeInterval)? {
        switch self {
        case .hour: nil
        case .day: ("5minute", 300)
        case .week: ("hour", 3600)
        }
    }
}

struct Threshold: Identifiable {
    let value: Double
    let tone: Tone
    var id: Double { value }
}

struct MetricInfo {
    let title: String
    let unit: String
    let marginUnit: String
    let decimals: Int
    /// minimum visible y span, so a flat line isn't blown up into noise
    let minSpan: Double
    /// the same levels the widget tiles colour by
    let thresholds: [Threshold]
    let higherIsWorse: Bool

    func format(_ v: Double) -> String { String(format: "%.\(decimals)f \(unit)", v) }

    /// thresholds are round numbers: "-24 dBm", not "-24.00 dBm"
    func level(_ v: Double) -> String { v == v.rounded() ? "\(Int(v)) \(unit)" : format(v) }
}

let metricInfo: [String: MetricInfo] = [
    "rx_power": MetricInfo(title: "RX Power", unit: "dBm", marginUnit: "dB", decimals: 2, minSpan: 0.3,
                           thresholds: [Threshold(value: -24, tone: .warning), Threshold(value: -27, tone: .danger)],
                           higherIsWorse: false),
    "tx_power": MetricInfo(title: "TX Power", unit: "dBm", marginUnit: "dB", decimals: 2, minSpan: 0.3,
                           thresholds: [], higherIsWorse: true),
    "optic_temperature": MetricInfo(title: "Optic temperature", unit: "°C", marginUnit: "°C", decimals: 1, minSpan: 3,
                                    thresholds: [Threshold(value: 60, tone: .warning), Threshold(value: 70, tone: .danger)],
                                    higherIsWorse: true),
    "latency": MetricInfo(title: "Latency", unit: "ms", marginUnit: "ms", decimals: 1, minSpan: 2,
                          thresholds: [Threshold(value: 40, tone: .warning), Threshold(value: 100, tone: .danger)],
                          higherIsWorse: true),
]

struct Point: Identifiable {
    let t: Date
    let mean: Double
    let min: Double
    let max: Double
    var id: Date { t }
}

struct Series: Identifiable {
    let id: String
    let entity: String
    let label: String
    let color: Color
    var points: [Point] = []
}

struct Segment: Identifiable {
    let lane: String
    let start: Date
    let end: Date
    let status: RowStatus
    let text: String
    var id: String { "\(lane)\(start.timeIntervalSince1970)" }
}

@MainActor
final class DetailModel: ObservableObject {
    let target: DetailTarget
    let provider: String
    let title: String
    let info: MetricInfo?
    @Published var range: TimeRange = .day {
        didSet { if range != oldValue { reload() } }
    }
    @Published private(set) var series: [Series] = []
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var window: ClosedRange<Date>
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var current = ""
    @Published private(set) var currentValue: Double?
    @Published var hover: Date?

    /// plot rect in the detail view's coordinates, reported by the chart, for mouse → date
    var plotFrame: CGRect = .zero
    private let lanes: [(name: String, entity: String)]
    private weak var client: HAClient?
    private weak var store: Store?
    private var rowWatch: AnyCancellable?
    private var refresh: Timer?
    private var task: Task<Void, Never>?

    var mainEntities: [String] { series.isEmpty ? lanes.map(\.entity) : series.map(\.entity) }
    var laneNames: [String] { lanes.map(\.name) }
    /// raw states (1h) hold until the next change; statistics are bucket means
    var isRaw: Bool { range.period == nil }

    init?(target: DetailTarget, store: Store, client: HAClient) {
        guard let spec = store.spec(for: target.row) else { return nil }
        self.target = target
        provider = spec.name
        self.store = store
        self.client = client
        let now = Date()
        window = now.addingTimeInterval(-TimeRange.day.seconds)...now
        switch target.kind {
        case .metric(let key):
            guard let info = metricInfo[key], let entity = key == "latency" ? spec.latency : spec.onu[key] else { return nil }
            title = info.title
            self.info = info
            lanes = []
            series = [Series(id: key, entity: entity, label: info.title, color: Color(red: 0.47, green: 0.52, blue: 1))]
        case .rates:
            title = "Throughput"
            info = nil
            lanes = []
            series = [("down", spec.rx, "Download", Color.blue), ("up", spec.tx, "Upload", Color.green)]
                .compactMap { id, entity, label, color in entity.map { Series(id: id, entity: $0, label: label, color: color) } }
            if series.isEmpty { return nil }
        case .status:
            title = "Status"
            info = nil
            lanes = [("WAN", spec.wanInternet ?? spec.ispStatus), ("PON", spec.onu["pon_link"])]
                .compactMap { name, entity in entity.map { (name, $0) } }
            if lanes.isEmpty { return nil }
        }
        rowWatch = store.$rows.sink { [weak self] rows in
            guard let self, let row = rows.first(where: { $0.id == target.row }) else { return }
            self.updateCurrent(row)
        }
    }

    func start() {
        reload()
        // statistics land every 5 min, raw states every few seconds; 30 s keeps both fresh enough
        refresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stop() {
        refresh?.invalidate()
        task?.cancel()
        rowWatch = nil
    }

    func reload() {
        task?.cancel()
        task = Task { await fetch() }
    }

    func fetch() async {
        guard let client else { return }
        let end = Date()
        let start = end.addingTimeInterval(-range.seconds)
        let range = self.range
        do {
            if lanes.isEmpty {
                let points = try await fetchSeries(client, start, end, range)
                guard !Task.isCancelled, range == self.range else { return }
                for i in series.indices { series[i].points = points[series[i].entity] ?? [] }
            } else {
                let segs = try await fetchSegments(client, start, end)
                guard !Task.isCancelled, range == self.range else { return }
                segments = segs
            }
            window = start...end
            error = nil
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: data

    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private func fetchSeries(_ client: HAClient, _ start: Date, _ end: Date, _ range: TimeRange) async throws -> [String: [Point]] {
        let ids = series.map(\.entity)
        if let period = range.period {
            let result = try await client.request("recorder/statistics_during_period", [
                "start_time": iso(start), "end_time": iso(end), "statistic_ids": ids,
                "period": period.name, "types": ["mean", "min", "max"],
                "units": ["data_rate": "bit/s"],
            ]) as? [String: [[String: Any]]] ?? [:]
            return result.mapValues { rows in
                rows.compactMap { r in
                    guard let ms = r["start"] as? Double, let mean = r["mean"] as? Double else { return nil }
                    // plot a bucket in its middle, so the last one sits next to "now"
                    let t = Date(timeIntervalSince1970: ms / 1000 + period.seconds / 2)
                    return Point(t: t, mean: mean, min: r["min"] as? Double ?? mean, max: r["max"] as? Double ?? mean)
                }
            }
        }
        let result = try await client.request("history/history_during_period", [
            "start_time": iso(start), "end_time": iso(end), "entity_ids": ids,
            "minimal_response": true, "no_attributes": true, "significant_changes_only": false,
        ]) as? [String: [[String: Any]]] ?? [:]
        var out: [String: [Point]] = [:]
        for (id, rows) in result {
            let scale = target.kind == .rates ? store?.rateScale(of: id) ?? 1 : 1
            var points: [Point] = rows.compactMap { r in
                guard let s = r["s"] as? String, let v = Double(s), let ts = (r["lu"] ?? r["lc"]) as? Double else { return nil }
                let t = Date(timeIntervalSince1970: max(ts, start.timeIntervalSince1970))
                return Point(t: t, mean: v * scale, min: v * scale, max: v * scale)
            }
            // a state holds until the next one: carry the last value to "now" like HA's graph
            if let last = points.last, last.t < end {
                points.append(Point(t: end, mean: last.mean, min: last.min, max: last.max))
            }
            out[id] = points
        }
        return out
    }

    private func fetchSegments(_ client: HAClient, _ start: Date, _ end: Date) async throws -> [Segment] {
        let result = try await client.request("history/history_during_period", [
            "start_time": iso(start), "end_time": iso(end), "entity_ids": lanes.map(\.entity),
            "minimal_response": true, "no_attributes": true,
        ]) as? [String: [[String: Any]]] ?? [:]
        var out: [Segment] = []
        for lane in lanes {
            let changes: [(Date, String)] = (result[lane.entity] ?? []).compactMap { r in
                guard let s = r["s"] as? String, let ts = (r["lu"] ?? r["lc"]) as? Double else { return nil }
                return (Date(timeIntervalSince1970: max(ts, start.timeIntervalSince1970)), s)
            }
            var merged: [(start: Date, status: RowStatus, text: String)] = []
            for (t, s) in changes {
                let (status, text) = Self.laneStatus(s)
                if merged.last?.status != status { merged.append((t, status, text)) }
            }
            for (i, m) in merged.enumerated() {
                let stop = i + 1 < merged.count ? merged[i + 1].start : end
                out.append(Segment(lane: lane.name, start: m.start, end: stop, status: m.status, text: m.text))
            }
        }
        return out
    }

    /// wan_internet_state 0/1/2/3, isp/pon binary on/off
    private static func laneStatus(_ s: String) -> (RowStatus, String) {
        switch s {
        case "1", "on": (.online, "Online")
        case "0", "off": (.offline, "Offline")
        case "2": (.connecting, "Connecting")
        case "3": (.connecting, "Disconnecting")
        default: (.unknown, "No data")
        }
    }

    private func updateCurrent(_ row: ProviderRow) {
        switch target.kind {
        case .metric(let key):
            current = row.stats.first { $0.key == key }?.value ?? "—"
            currentValue = series.first.flatMap { store?.number($0.entity) }
        case .rates:
            current = "↓ \(row.down)   ↑ \(row.up)"
        case .status:
            current = row.statusText
        }
    }

    // MARK: derived

    /// raw: the state in force at t; statistics: the closest bucket
    func nearest(_ s: Series, to t: Date) -> Point? {
        if isRaw { return s.points.last { $0.t <= t } ?? s.points.first }
        return s.points.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }

    func fraction(_ t: Date) -> CGFloat {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        return span > 0 ? CGFloat(t.timeIntervalSince(window.lowerBound) / span) : 0
    }

    func hoverDate(atX x: CGFloat) -> Date? {
        guard plotFrame.width > 0, x >= plotFrame.minX, x <= plotFrame.maxX else { return nil }
        let frac = (x - plotFrame.minX) / plotFrame.width
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        return window.lowerBound.addingTimeInterval(span * frac)
    }

    var yDomain: ClosedRange<Double> {
        let all = series.flatMap(\.points)
        guard var lo = all.map(\.min).min(), var hi = all.map(\.max).max() else { return 0...1 }
        if target.kind == .rates { return 0...max(hi * 1.1, 1000) }
        let span = max(hi - lo, info?.minSpan ?? 1)
        let mid = (hi + lo) / 2
        lo = mid - span / 2
        hi = mid + span / 2
        let pad = span * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// thresholds only when they fall inside the auto-scaled range; otherwise the footer gives the margin
    var visibleThresholds: [Threshold] {
        guard let info else { return [] }
        return info.thresholds.filter { yDomain.contains($0.value) }
    }

    var marginText: (String, Tone)? {
        guard let info, let cur = currentValue, let warn = info.thresholds.first else { return nil }
        let danger = info.thresholds.dropFirst().first
        let past = { (th: Threshold) in info.higherIsWorse ? cur >= th.value : cur <= th.value }
        if let danger, past(danger) { return ("past critical level \(info.level(danger.value))", .danger) }
        if past(warn) { return ("past warning level \(info.level(warn.value))", .warning) }
        let margin = abs(cur - warn.value)
        return (String(format: "%.1f \(info.marginUnit) to warning (\(info.level(warn.value)))", margin), .normal)
    }

    var summary: String {
        if !lanes.isEmpty { return statusSummary }
        if target.kind == .rates {
            return series.map { s in
                let peak = s.points.map(\.max).max() ?? 0
                let avg = s.points.isEmpty ? 0 : s.points.map(\.mean).reduce(0, +) / Double(s.points.count)
                return "\(s.id == "down" ? "↓" : "↑") avg \(Format.bitRate(avg)) · peak \(Format.bitRate(peak))"
            }.joined(separator: "   ")
        }
        guard let info, let s = series.first, !s.points.isEmpty,
              let lo = s.points.map(\.min).min(), let hi = s.points.map(\.max).max() else { return "" }
        let avg = s.points.map(\.mean).reduce(0, +) / Double(s.points.count)
        let f = { (v: Double) in String(format: "%.\(info.decimals)f", v) }
        return "min \(f(lo)) · avg \(f(avg)) · max \(f(hi)) \(info.unit)"
    }

    private var statusSummary: String {
        let wan = segments.filter { $0.lane == lanes.first?.name }
        let known = wan.filter { $0.status != .unknown }
        let total = known.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let up = known.filter { $0.status == .online }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let outages = wan.filter { $0.status == .offline }
        var text = total > 0 ? String(format: "Uptime %.2f %%", up / total * 100) : "No data"
        text += outages.isEmpty ? " · no outages" : " · \(outages.count) outage\(outages.count == 1 ? "" : "s")"
        if let last = outages.last {
            text += " · last \(last.start.formatted(.dateTime.day().month(.abbreviated).hour().minute())), \(duration(last.end.timeIntervalSince(last.start)))"
        }
        return text
    }

    func hoverText(_ t: Date) -> String {
        let time = t.formatted(range == .week ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute())
        if !lanes.isEmpty {
            let parts = segments.filter { $0.start <= t && t < $0.end }.map {
                "\($0.lane) \($0.text) \($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)) (\(duration($0.end.timeIntervalSince($0.start))))"
            }
            return parts.isEmpty ? "\(time)  no data" : parts.joined(separator: " · ")
        }
        if target.kind == .rates {
            let parts = series.compactMap { s in nearest(s, to: t).map { "\(s.id == "down" ? "↓" : "↑") \(Format.bitRate($0.mean))" } }
            return "\(time)  " + parts.joined(separator: "  ")
        }
        guard let info, let s = series.first, let p = nearest(s, to: t) else { return time }
        if range.period == nil { return "\(time)  \(info.format(p.mean))" }
        let f = { (v: Double) in String(format: "%.\(info.decimals)f", v) }
        return "\(time)  \(info.format(p.mean))  (min \(f(p.min)) / max \(f(p.max)))"
    }

    private func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 1 { return "\(Int(s))s" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return h < 24 ? "\(h)h \(m % 60)m" : "\(h / 24)d \(h % 24)h"
    }

    func historyURL(base: URL) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "entity_id", value: mainEntities.joined(separator: ",")),
            URLQueryItem(name: "start_date", value: iso(window.lowerBound)),
        ]
        return c.url!
    }
}
