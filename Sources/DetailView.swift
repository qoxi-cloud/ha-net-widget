import Charts
import SwiftUI

struct PlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

let detailWidth: CGFloat = widgetWidth

/// fills whatever height the panel gets (the widget's); the chart takes the slack
struct DetailView: View {
    @ObservedObject var model: DetailModel
    var openInHA: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.provider).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.title).font(.system(size: 15, weight: .semibold))
                }
                Spacer(minLength: 8)
                Text(model.current)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack {
                rangePicker
                Spacer(minLength: 8)
                zoomControls
            }

            ZStack {
                if model.target.kind == .status { StatusTimeline(model: model) } else { MetricChart(model: model) }
                if model.noData {
                    Text("No data for this period").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !model.loaded {
                    if let error = model.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(minHeight: model.target.kind == .status ? 74 : 150, maxHeight: .infinity)

            Text(model.hover.map(model.hoverText) ?? model.summary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack {
                if let (text, tone) = model.marginText {
                    Text(text).font(.system(size: 11)).foregroundStyle(toneColor(tone))
                }
                Spacer()
                Button(action: { openInHA?() }) {
                    Text("Open in HA ↗").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: detailWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named("detail"))
        .onPreferenceChange(PlotFrameKey.self) { model.plotFrame = $0 }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { r in
                // the selected range again = zoom back out
                Button(action: { if model.range == r { model.resetZoom() } else { model.range = r } }) {
                    Text(r.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(model.range == r ? Color.primary.opacity(0.16) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.range == r ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass", enabled: model.canZoomOut) { model.zoom(by: 2) }
            if let label = model.zoomLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            zoomButton("plus.magnifyingglass", enabled: model.canZoomIn) { model.zoom(by: 0.5) }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func zoomButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

func toneColor(_ tone: Tone) -> Color {
    switch tone {
    case .normal: .secondary
    case .warning: .orange
    case .danger: .red
    }
}

/// midnight names the day (a week shows only days), other ticks the time
private func tickLabel(_ t: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: t)
    return t.formatted(c.hour == 0 && c.minute == 0 ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute())
}

/// round ticks (:15, every 6 h, midnight) at the finest step that leaves room for the
/// labels, kept clear of the edges, where labels would be clipped
private func xTicks(_ w: ClosedRange<Date>) -> [Date] {
    let steps: [(Calendar.Component, Int)] = [
        (.minute, 1), (.minute, 2), (.minute, 5), (.minute, 10), (.minute, 15), (.minute, 30),
        (.hour, 1), (.hour, 2), (.hour, 3), (.hour, 6), (.hour, 12), (.day, 1),
    ]
    let span = w.upperBound.timeIntervalSince(w.lowerBound)
    let seconds = { (s: (Calendar.Component, Int)) in Double(s.1) * (s.0 == .minute ? 60 : s.0 == .hour ? 3600 : 86400) }
    // weekday labels are narrower than times
    let step = steps.first { span / seconds($0) <= ($0.0 == .day ? 7.5 : 5) } ?? (.day, 1)
    let cal = Calendar.current
    var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: w.lowerBound)
    switch step.0 {
    case .minute: c.minute = (c.minute ?? 0) / step.1 * step.1
    case .hour: c.minute = 0; c.hour = (c.hour ?? 0) / step.1 * step.1
    default: c.minute = 0; c.hour = 0
    }
    var t = cal.date(from: c) ?? w.lowerBound
    var out: [Date] = []
    while t <= w.upperBound {
        if t.timeIntervalSince(w.lowerBound) > span * 0.04, w.upperBound.timeIntervalSince(t) > span * 0.07 { out.append(t) }
        guard let next = cal.date(byAdding: step.0, value: step.1, to: t) else { break }
        t = next
    }
    return out
}

/// same decimal point as the rest of the widget, whatever the region setting
private let posix = Locale(identifier: "en_US_POSIX")

/// reports the plot rect in "detail" coordinates, so mouse x maps to a date
private struct PlotReporter: View {
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .named("detail")).origin
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            Color.clear.preference(key: PlotFrameKey.self, value: plot.offsetBy(dx: origin.x, dy: origin.y))
        }
    }
}

private struct MetricChart: View {
    @ObservedObject var model: DetailModel

    var body: some View {
        let banded = !model.isRaw
        Chart {
            ForEach(model.series) { s in
                if banded {
                    ForEach(s.points) { p in
                        AreaMark(x: .value("Time", p.t), yStart: .value("Min", p.min), yEnd: .value("Max", p.max),
                                 series: .value("Series", s.id))
                            .foregroundStyle(s.color.opacity(0.18))
                    }
                }
                ForEach(s.points) { p in
                    LineMark(x: .value("Time", p.t), y: .value("Value", p.mean), series: .value("Series", s.id))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(model.isRaw ? .stepEnd : .linear)
                }
            }
            ForEach(model.visibleThresholds) { th in
                RuleMark(y: .value("Threshold", th.value))
                    .foregroundStyle(toneColor(th.tone).opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let h = model.hover {
                RuleMark(x: .value("Hover", h))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(model.series) { s in
                    if let p = model.nearest(s, to: h) {
                        PointMark(x: .value("Time", model.isRaw ? h : p.t), y: .value("Value", p.mean))
                            .foregroundStyle(s.color)
                            .symbolSize(28)
                    }
                }
            }
        }
        .chartXScale(domain: model.visible)
        .chartYScale(domain: model.yDomain)
        // zoomed: points past the edges (the padding bucket, the old data before a refetch)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: xTicks(model.visible)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel(anchor: .top) {
                    if let d = v.as(Date.self) { Text(tickLabel(d)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(model.target.kind == .rates ? shortRate(d) : d.formatted(.number.precision(.fractionLength(0...2)).locale(posix)))
                    }
                }
            }
        }
        .chartOverlay { PlotReporter(proxy: $0) }
    }

    private func shortRate(_ v: Double) -> String {
        let trim = { (x: Double) in x.formatted(.number.precision(.fractionLength(0...1)).locale(posix)) }
        if v >= 1e9 { return trim(v / 1e9) + "G" }
        if v >= 1e6 { return trim(v / 1e6) + "M" }
        if v >= 1e3 { return trim(v / 1e3) + "k" }
        return trim(v)
    }
}

/// drawn by hand: Charts puts categorical axis labels on top of the bars
private struct StatusTimeline: View {
    @ObservedObject var model: DetailModel
    private let labelWidth: CGFloat = 30
    private let laneHeight: CGFloat = 16
    private let laneGap: CGFloat = 6

    var body: some View {
        let lanes = model.laneNames
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: laneGap) {
                ForEach(lanes, id: \.self) { lane in
                    HStack(spacing: 8) {
                        Text(lane)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        GeometryReader { geo in bar(lane, width: geo.size.width) }
                            .frame(height: laneHeight)
                    }
                }
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: labelWidth, height: 1)
                GeometryReader { geo in
                    ForEach(xTicks(model.visible), id: \.self) { t in
                        Text(tickLabel(t))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: model.fraction(t) * geo.size.width, y: 7)
                    }
                }
                .frame(height: 14)
            }
        }
        .background(GeometryReader { geo in
            // hover area = the bars, in "detail" coordinates
            let f = geo.frame(in: .named("detail"))
            let height = CGFloat(lanes.count) * (laneHeight + laneGap)
            Color.clear.preference(key: PlotFrameKey.self,
                                   value: CGRect(x: f.minX + labelWidth + 8, y: f.minY, width: f.width - labelWidth - 8, height: height))
        })
    }

    private func bar(_ lane: String, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.primary.opacity(0.06)
            ForEach(model.segments.filter { $0.lane == lane }) { seg in
                let x = model.fraction(seg.start) * width
                Rectangle()
                    .fill(color(seg.status))
                    // a 2-minute outage in a week is a fraction of a point; keep it visible
                    .frame(width: max(model.fraction(seg.end) * width - x, seg.status == .online ? 1 : 2))
                    .offset(x: x)
            }
            if let h = model.hover {
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1).offset(x: model.fraction(h) * width)
            }
        }
        // zoomed, a segment can be far wider than the lane; keep the lane's width
        .frame(width: width, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func color(_ s: RowStatus) -> Color {
        switch s {
        case .online: .green.opacity(0.75)
        case .warning, .connecting: .orange
        case .offline: .red
        case .unknown: .gray.opacity(0.4)
        }
    }
}
