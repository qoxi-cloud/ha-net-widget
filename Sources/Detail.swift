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
}

/// long-term statistics bucket
struct Period: Equatable {
    let name: String
    let seconds: TimeInterval

    static let fiveMinute = Period(name: "5minute", seconds: 300)
    static let hour = Period(name: "hour", seconds: 3600)

    /// finest data that stays a few hundred points: raw states up to 3 h, 5-minute
    /// buckets up to 2 days, hourly beyond (1h / 24h / 7d land on one each)
    static func fitting(_ span: TimeInterval) -> Period? {
        span <= 3 * 3600 ? nil : span <= 2 * 86400 ? .fiveMinute : .hour
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
        didSet {
            guard range != oldValue else { return }
            zoomed = nil
            reload()
        }
    }
    @Published private(set) var series: [Series] = []
    @Published private(set) var segments: [Segment] = []
    /// the whole range; `zoomed` is the part on screen when zoomed in
    @Published private(set) var window: ClosedRange<Date>
    @Published private(set) var zoomed: ClosedRange<Date>?
    /// bucket of the points in `series`; nil = raw states
    @Published private(set) var period: Period? = .fiveMinute
    /// what `series` was last fetched for, so "no data" isn't claimed while a refetch is due
    @Published private(set) var fetchedFor: ClosedRange<Date>?
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
    /// raw states hold until the next change; statistics are bucket means
    var isRaw: Bool { period == nil }
    var visible: ClosedRange<Date> { zoomed ?? window }
    var span: TimeInterval { visible.upperBound.timeIntervalSince(visible.lowerBound) }

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
        let now = Date()
        let follow = followsNow
        window = now.addingTimeInterval(-range.seconds)...now
        // a zoom on the latest data moves along with "now"; one on older data stays put
        if let z = zoomed {
            let shift = follow ? now.timeIntervalSince(z.upperBound) : 0
            zoomed = clamp(z.lowerBound.addingTimeInterval(shift), z.upperBound.timeIntervalSince(z.lowerBound))
        }
        task?.cancel()
        task = Task { await fetch() }
    }

    /// zoom and pan come in bursts (scroll momentum, a pinch): fetch once they settle
    private func refetchSoon() {
        guard lanes.isEmpty else { return } // the timeline already has the whole range
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await fetch()
        }
    }

    func fetch() async {
        guard let client else { return }
        let shown = visible
        let period = Period.fitting(span)
        do {
            if lanes.isEmpty {
                let points = try await fetchSeries(client, shown, period)
                guard !Task.isCancelled else { return }
                for i in series.indices { series[i].points = points[series[i].entity] ?? [] }
                self.period = period
                fetchedFor = shown
            } else {
                let segs = try await fetchSegments(client, window.lowerBound, window.upperBound)
                guard !Task.isCancelled else { return }
                segments = segs
            }
            error = nil
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: data

    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private func fetchSeries(_ client: HAClient, _ shown: ClosedRange<Date>, _ period: Period?) async throws -> [String: [Point]] {
        let ids = series.map(\.entity)
        let (start, end) = (shown.lowerBound, shown.upperBound)
        if let period {
            let result = try await client.request("recorder/statistics_during_period", [
                // a bucket past each edge, so the line runs to the edges of a zoomed view
                "start_time": iso(start.addingTimeInterval(-period.seconds)),
                "end_time": iso(end.addingTimeInterval(period.seconds)), "statistic_ids": ids,
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

    // MARK: zoom

    /// shortest zoom: still a handful of raw states
    private static let minZoom: TimeInterval = 5 * 60

    var canZoomIn: Bool { span > Self.minZoom * 1.01 }
    var canZoomOut: Bool { zoomed != nil }
    private var followsNow: Bool { window.upperBound.timeIntervalSince(visible.upperBound) < 1 }

    /// factor < 1 zooms in. The anchor stays where it is on screen: the cursor for a
    /// pinch, otherwise "now" while the view ends there, else the middle.
    func zoom(by factor: Double, around anchor: Date? = nil) {
        let full = window.upperBound.timeIntervalSince(window.lowerBound)
        let newSpan = min(max(span * factor, Self.minZoom), full)
        let a = anchor ?? (followsNow ? visible.upperBound : visible.lowerBound.addingTimeInterval(span / 2))
        setZoom(clamp(a.addingTimeInterval(-a.timeIntervalSince(visible.lowerBound) * newSpan / span), newSpan))
    }

    /// share of the visible width; positive = later
    func pan(by share: Double) {
        guard zoomed != nil else { return }
        setZoom(clamp(visible.lowerBound.addingTimeInterval(span * share), span))
    }

    func resetZoom() { setZoom(nil) }

    private func setZoom(_ z: ClosedRange<Date>?) {
        guard z != zoomed else { return }
        zoomed = z
        refetchSoon()
    }

    /// slid back inside the range; nil once it covers all of it
    private func clamp(_ lower: Date, _ span: TimeInterval) -> ClosedRange<Date>? {
        guard span < window.upperBound.timeIntervalSince(window.lowerBound) - 1 else { return nil }
        let lo = min(max(lower, window.lowerBound), window.upperBound.addingTimeInterval(-span))
        return lo...lo.addingTimeInterval(span)
    }

    /// "45m", "6h", "3.5d"; nil when not zoomed
    var zoomLabel: String? {
        guard zoomed != nil else { return nil }
        let m = span / 60
        if m < 120 { return "\(Int(m.rounded()))m" }
        if m < 72 * 60 { return "\(Int((m / 60).rounded()))h" }
        return String(format: "%.1fd", m / 1440)
    }

    // MARK: derived

    /// the fetch pads a bucket past each edge; summaries and scaling use what's on screen
    private func shown(_ s: Series) -> [Point] {
        let v = visible
        let inside = s.points.filter { v.contains($0.t) }
        return inside.isEmpty ? s.points : inside
    }

    /// raw: the state in force at t; statistics: the closest bucket
    func nearest(_ s: Series, to t: Date) -> Point? {
        if isRaw { return s.points.last { $0.t <= t } ?? s.points.first }
        return s.points.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }

    func fraction(_ t: Date) -> CGFloat {
        span > 0 ? CGFloat(t.timeIntervalSince(visible.lowerBound) / span) : 0
    }

    func hoverDate(atX x: CGFloat) -> Date? {
        guard plotFrame.width > 0, x >= plotFrame.minX, x <= plotFrame.maxX else { return nil }
        return visible.lowerBound.addingTimeInterval(span * (x - plotFrame.minX) / plotFrame.width)
    }

    var noData: Bool {
        let v = visible
        return lanes.isEmpty && fetchedFor == v && !series.contains { $0.points.contains { v.contains($0.t) } }
    }

    var yDomain: ClosedRange<Double> {
        let all = series.flatMap(shown)
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
                let points = shown(s)
                let peak = points.map(\.max).max() ?? 0
                let avg = points.isEmpty ? 0 : points.map(\.mean).reduce(0, +) / Double(points.count)
                return "\(s.id == "down" ? "↓" : "↑") avg \(Format.bitRate(avg)) · peak \(Format.bitRate(peak))"
            }.joined(separator: "   ")
        }
        guard let info, let points = series.first.map(shown), !points.isEmpty,
              let lo = points.map(\.min).min(), let hi = points.map(\.max).max() else { return "" }
        let avg = points.map(\.mean).reduce(0, +) / Double(points.count)
        let f = { (v: Double) in String(format: "%.\(info.decimals)f", v) }
        return "min \(f(lo)) · avg \(f(avg)) · max \(f(hi)) \(info.unit)"
    }

    private var statusSummary: String {
        let v = visible
        let wan = segments.filter { $0.lane == lanes.first?.name && $0.end > v.lowerBound && $0.start < v.upperBound }
        let length = { (s: Segment) in min(s.end, v.upperBound).timeIntervalSince(max(s.start, v.lowerBound)) }
        let known = wan.filter { $0.status != .unknown }
        let total = known.reduce(0) { $0 + length($1) }
        let up = known.filter { $0.status == .online }.reduce(0) { $0 + length($1) }
        let outages = wan.filter { $0.status == .offline }
        var text = total > 0 ? String(format: "Uptime %.2f %%", up / total * 100) : "No data"
        text += outages.isEmpty ? " · no outages" : " · \(outages.count) outage\(outages.count == 1 ? "" : "s")"
        if let last = outages.last {
            text += " · last \(last.start.formatted(.dateTime.day().month(.abbreviated).hour().minute())), \(duration(last.end.timeIntervalSince(last.start)))"
        }
        return text
    }

    func hoverText(_ t: Date) -> String {
        let time = t.formatted(span > 86400 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute())
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
        if isRaw { return "\(time)  \(info.format(p.mean))" }
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
            URLQueryItem(name: "start_date", value: iso(visible.lowerBound)),
            URLQueryItem(name: "end_date", value: iso(visible.upperBound)),
        ]
        return c.url!
    }
}
