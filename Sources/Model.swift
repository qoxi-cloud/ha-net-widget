import Foundation

struct EntityState {
    var state: String
    var attributes: [String: Any]
}

enum Tone { case normal, warning, danger }

enum RowStatus {
    case online, warning, connecting, offline, unknown
}

struct Stat: Identifiable {
    let label: String
    let value: String
    var tone: Tone = .normal
    var id: String { label }
}

struct ProviderRow: Identifiable {
    let id: String
    let name: String
    let status: RowStatus
    let statusText: String
    let ip: String
    let ipPublic: Bool
    let ponMode: String
    let ponRates: String
    let down: String
    let up: String
    let stats: [Stat]
}

/// One ISP = an OmadaBridge WAN link + the ONU stick behind it + the switch-port
/// throughput sensors. Same discovery rules as the dashboard's ISP/ONU cards
/// (qoxi Mushroom fork: isp-model.ts, onu-model.ts), so renames on the HA side
/// need no change here.
struct ProviderSpec {
    let name: String
    let port: Int
    let latency: String
    let wanStatus: String?
    let wanInternet: String?
    let ispStatus: String?
    let rx: String?
    let tx: String?
    let onu: [String: String]

    var entityIds: [String] {
        [latency, wanStatus, wanInternet, ispStatus, rx, tx].compactMap { $0 } + onu.values
    }
}

let bitScale: [String: Double] = [
    "bit/s": 1, "kbit/s": 1e3, "Mbit/s": 1e6, "Gbit/s": 1e9,
    "B/s": 8, "kB/s": 8e3, "KB/s": 8e3, "MB/s": 8e6, "GB/s": 8e9,
]

enum Discovery {
    static let onuMetrics: Set<String> = [
        "pon_link", "pon_alarms", "pon_state", "pon_mode",
        "rx_power", "tx_power", "optic_temperature",
    ]
    private static let onuRe = try! NSRegularExpression(
        pattern: #"^(?:sensor|binary_sensor)\.(?:8311_onu_|net_onu_)([a-z0-9]+)_(.+)$"#)
    private static let wanRe = try! NSRegularExpression(
        pattern: #"^sensor\.(.+?)_wan_latency_port_(\d+)_(.+)$"#)

    static func providers(from states: [String: EntityState]) -> [ProviderSpec] {
        var onus: [String: [String: String]] = [:]
        for id in states.keys {
            guard let m = match(onuRe, id), onuMetrics.contains(m[1]) else { continue }
            onus[m[0], default: [:]][m[1]] = id
        }
        let onuTokens = onus.mapValues { metrics -> Set<String> in
            let link = metrics["pon_link"].flatMap { states[$0] }
            let name = (link?.attributes["friendly_name"] as? String ?? "")
            return Set(tokens(name))
        }

        var out: [ProviderSpec] = []
        for (id, st) in states {
            guard let m = match(wanRe, id), let port = Int(m[1]) else { continue }
            let (gw, slug) = (m[0], m[2])
            let suffix = "port_\(port)_\(slug)"
            let exists = { (eid: String) in states[eid] != nil ? eid : nil }
            let wanStatus = exists("sensor.\(gw)_wan_status_\(suffix)")
            let attrs = wanStatus.flatMap { states[$0]?.attributes } ?? st.attributes
            let raw = (attrs["desc"] as? String) ?? (attrs["name"] as? String) ?? slug
            let name = raw.split(whereSeparator: { " _-".contains($0) }).first.map(String.init) ?? raw
            let token = name.lowercased()
            let serial = onuTokens.first { $0.value.contains(token) }?.key
            out.append(ProviderSpec(
                name: name,
                port: port,
                latency: id,
                wanStatus: wanStatus,
                wanInternet: exists("sensor.\(gw)_wan_internet_state_\(suffix)"),
                ispStatus: exists("binary_sensor.\(gw)_isp_status_\(suffix)"),
                rx: trafficSensor(states, "\(token) download"),
                tx: trafficSensor(states, "\(token) upload"),
                onu: serial.flatMap { onus[$0] } ?? [:]))
        }
        return out.sorted { ($0.port, $0.name) < ($1.port, $1.name) }
    }

    /// "<isp> download" / "<isp> upload" by friendly name, any bit/s or B/s unit
    private static func trafficSensor(_ states: [String: EntityState], _ want: String) -> String? {
        states.first { id, st in
            guard id.hasPrefix("sensor."),
                  let unit = st.attributes["unit_of_measurement"] as? String, bitScale[unit] != nil
            else { return false }
            let name = (st.attributes["friendly_name"] as? String ?? "").lowercased()
                .trimmingCharacters(in: .whitespaces)
            return name == want || name.hasSuffix(" " + want)
        }?.key
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 }
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range) else { return nil }
        return (1..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
    }
}

enum Format {
    /// value never wider than 3 characters, like the ISP card ("999", "1.7", "10")
    static func bitRate(_ bps: Double) -> String {
        for (div, unit) in [(1e9, "Gbit/s"), (1e6, "Mbit/s"), (1e3, "kbit/s")] {
            let n = bps / div
            if n < 0.9995 { continue }
            if div == 1e3 { return "\(String(format: "%.0f", n)) \(unit)" }
            return "\(String(format: n >= 9.95 ? "%.0f" : "%.1f", n)) \(unit)"
        }
        return "\(String(format: "%.0f", max(0, bps))) bit/s"
    }

    static func latency(_ ms: Double) -> String {
        ms <= 0 ? "—" : String(format: ms < 10 ? "%.1f ms" : "%.0f ms", ms)
    }

    /// nominal line rates of a PON technology: "XG-PON" → "↓10G ↑2.5G"
    static func ponRates(_ mode: String) -> String {
        let key = mode.uppercased().filter { !" _-".contains($0) }
        let table: [String: (Double, Double)] = [
            "GPON": (2.5, 1.25), "XGPON": (10, 2.5), "XGSPON": (10, 10),
            "NGPON2": (10, 10), "25GPON": (25, 25), "50GPON": (50, 25),
        ]
        guard let (d, u) = table[key] else { return "" }
        let g = { (v: Double) in v == v.rounded() ? "\(Int(v))G" : "\(v)G" }
        return "↓\(g(d)) ↑\(g(u))"
    }

    /// "O5 - Operation state" → "O5" (the full name doesn't fit a medium-widget width)
    static func ponState(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? ""
    }

    /// RFC1918, CGNAT, link-local, loopback and unset addresses are "local"
    static func isPublicIp(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        let (a, b) = (p[0], p[1])
        return !(a == 0 || a == 10 || a == 127 || (a == 100 && (64...127).contains(b))
            || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168))
    }
}
