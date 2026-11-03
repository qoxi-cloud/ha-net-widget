import SwiftUI

/// two macOS small widgets plus their gap (164 + 16 + 164), so it lines up under them
let widgetWidth: CGFloat = 344

/// tile frames in widget coordinates; the hosting view hit-tests clicks against them
/// (SwiftUI taps can't tell a click from a window drag, the mouse never moves in the view)
final class HitMap {
    var frames: [DetailTarget: CGRect] = [:]

    func target(at p: CGPoint) -> DetailTarget? { frames.first { $0.value.contains(p) }?.key }
}

private struct TileFrameKey: PreferenceKey {
    static let defaultValue: [DetailTarget: CGRect] = [:]
    static func reduce(value: inout [DetailTarget: CGRect], nextValue: () -> [DetailTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func clickTarget(_ target: DetailTarget) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: TileFrameKey.self, value: [target: g.frame(in: .named("widget"))])
        })
    }
}

struct WidgetView: View {
    @ObservedObject var store: Store
    var hitMap: HitMap?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            if store.rows.isEmpty {
                Text(store.link == .connecting ? "Connecting to Home Assistant…" : "No data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.5).padding(.vertical, 12) }
                RowView(row: row)
            }
        }
        .padding(16)
        .frame(width: widgetWidth, alignment: .leading)
        .opacity(isOffline ? 0.6 : 1)
        .coordinateSpace(.named("widget"))
        .onPreferenceChange(TileFrameKey.self) { [hitMap] in hitMap?.frames = $0 }
    }

    private var isOffline: Bool {
        if case .offline = store.link { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
            Text("Internet")
            Spacer()
            linkBadge
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var linkBadge: some View {
        switch store.link {
        case .connecting:
            Text("connecting…")
        case .live:
            let online = store.rows.filter { $0.status == .online }.count
            HStack(spacing: 5) {
                if store.viaCloud { Image(systemName: "cloud") }
                Circle().fill(online == store.rows.count ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text("\(online)/\(store.rows.count) online")
            }
        case .offline(let since, let reason):
            Text("offline since \(since.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.orange)
                .help(reason)
        }
    }
}

private struct RowView: View {
    let row: ProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                identity.clickTarget(DetailTarget(row: row.id, kind: .status))
                Spacer(minLength: 6)
                rates.clickTarget(DetailTarget(row: row.id, kind: .rates))
            }

            HStack(spacing: 6) {
                ForEach(row.stats) { stat in
                    StatTile(stat: stat).clickTarget(DetailTarget(row: row.id, kind: .metric(stat.key)))
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(statusColor.opacity(0.2))
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.name).font(.system(size: 14, weight: .semibold)).fixedSize()
                    if !row.ponMode.isEmpty {
                        Text("\(row.ponMode) \(row.ponRates)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 0) {
                    Text(row.statusText).foregroundStyle(.secondary)
                    if !row.ip.isEmpty {
                        Text(" · ").foregroundStyle(.secondary)
                        Text(row.ip).foregroundStyle(row.ipPublic ? Color.green : Color.orange)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
        }
    }

    /// fixed box sized for the widest value, left-aligned like the ISP card:
    /// the arrows stay put whatever the number of digits
    private var rates: some View {
        ZStack(alignment: .leading) {
            rate("arrow.down", "999 Mbit/s", .clear).hidden()
            VStack(alignment: .leading, spacing: 2) {
                rate("arrow.down", row.down, .blue)
                rate("arrow.up", row.up, .green)
            }
        }
    }

    private func rate(_ symbol: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
            Text(value).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .online: .green
        case .warning, .connecting: .orange
        case .offline: .red
        case .unknown: .gray
        }
    }
}

private struct StatTile: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(stat.value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var color: Color {
        switch stat.tone {
        case .normal: .primary
        case .warning: .orange
        case .danger: .red
        }
    }
}
