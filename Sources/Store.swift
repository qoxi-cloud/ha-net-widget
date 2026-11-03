import Foundation
import Combine

enum LinkState: Equatable {
    case connecting
    case live
    case offline(since: Date, reason: String)
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var rows: [ProviderRow] = []
    @Published private(set) var link: LinkState = .connecting
    @Published private(set) var viaCloud = false

    private var states: [String: EntityState] = [:]
    private var specs: [ProviderSpec] = []

    /// reconnects (wake, LAN ↔ cloud switch) keep the last state until they succeed or give up;
    /// retries keep the first failure time, so "offline since" stays honest
    func setLink(_ new: LinkState, viaCloud cloud: Bool = false) {
        if case .offline = link, case .offline = new { return }
        link = new
        viaCloud = cloud
    }

    /// full `get_states` snapshot → (re)discover providers, return the ids to subscribe to
    func load(_ all: [String: EntityState]) -> [String] {
        specs = Discovery.providers(from: all)
        let ids = Set(specs.flatMap(\.entityIds))
        states = all.filter { ids.contains($0.key) }
        rebuild()
        return ids.sorted()
    }

    /// compressed `subscribe_entities` event: a = added, c = changed (+/- diff), r = removed
    func apply(_ event: [String: Any]) {
        if let added = event["a"] as? [String: [String: Any]] {
            for (id, v) in added {
                states[id] = EntityState(state: v["s"] as? String ?? "", attributes: v["a"] as? [String: Any] ?? [:])
            }
        }
        if let changed = event["c"] as? [String: [String: Any]] {
            for (id, diff) in changed {
                guard var st = states[id] else { continue }
                if let plus = diff["+"] as? [String: Any] {
                    if let s = plus["s"] as? String { st.state = s }
                    if let a = plus["a"] as? [String: Any] { st.attributes.merge(a) { $1 } }
                }
                if let minus = diff["-"] as? [String: Any], let keys = minus["a"] as? [String] {
                    keys.forEach { st.attributes.removeValue(forKey: $0) }
                }
                states[id] = st
            }
        }
        if let removed = event["r"] as? [String] {
            removed.forEach { states.removeValue(forKey: $0) }
        }
        rebuild()
    }

    private func rebuild() {
        let new = specs.map(row)
        if new.map(\.signature) != rows.map(\.signature) { rows = new }
    }

    private func value(_ id: String?) -> String? {
        guard let id, let s = states[id]?.state, s != "unknown", s != "unavailable", !s.isEmpty else { return nil }
        return s
    }

    private func number(_ id: String?) -> Double? { value(id).flatMap(Double.init) }

    private func bits(_ id: String?) -> Double? {
        guard let id, let n = number(id) else { return nil }
        let unit = states[id]?.attributes["unit_of_measurement"] as? String ?? "bit/s"
        return n * (bitScale[unit] ?? 1)
    }

    private func row(_ p: ProviderSpec) -> ProviderRow {
        // WAN: same precedence as the ISP card (status → internet state → ISP binary)
        let wan: RowStatus
        let wanText: String
        if number(p.wanStatus) == 0 {
            (wan, wanText) = (.offline, "Offline")
        } else {
            switch number(p.wanInternet).map(Int.init) {
            case 0: (wan, wanText) = (.offline, "Offline")
            case 1: (wan, wanText) = (.online, "Online")
            case 2: (wan, wanText) = (.connecting, "Connecting")
            case 3: (wan, wanText) = (.connecting, "Disconnecting")
            default:
                switch value(p.ispStatus) {
                case "on": (wan, wanText) = (.online, "Online")
                case "off": (wan, wanText) = (.offline, "Offline")
                default: (wan, wanText) = (.unknown, "No data")
                }
            }
        }

        let ponLink = value(p.onu["pon_link"])
        let alarm = value(p.onu["pon_alarms"]) == "on"
        var status = wan
        if ponLink == "off" { status = .offline }
        else if status == .online && alarm { status = .warning }

        let ponState = value(p.onu["pon_state"]).map(Format.ponState) ?? ""
        let text = ponLink == "off" && wan != .offline ? "PON down" : wanText
        let ponMode = value(p.onu["pon_mode"]) ?? ""

        let ipAttrs = [p.wanStatus, p.ispStatus, p.latency].compactMap { $0.flatMap { states[$0]?.attributes } }
        let ip = ipAttrs.lazy.compactMap { $0["ip"] as? String }.first { !$0.isEmpty } ?? ""

        let rx = number(p.onu["rx_power"])
        let tx = number(p.onu["tx_power"])
        let optic = number(p.onu["optic_temperature"])
        let latency = number(p.latency)
        let dash = "—"

        var stats: [Stat] = []
        if !p.onu.isEmpty {
            stats += [
                Stat(label: "RX", value: rx.map { String(format: "%.1f dBm", $0) } ?? dash,
                     tone: rx.map { $0 <= -27 ? .danger : $0 <= -24 ? .warning : .normal } ?? .normal),
                Stat(label: "TX", value: tx.map { String(format: "%.1f dBm", $0) } ?? dash),
                Stat(label: "Optic", value: optic.map { String(format: "%.0f °C", $0) } ?? dash,
                     tone: optic.map { $0 >= 70 ? .danger : $0 >= 60 ? .warning : .normal } ?? .normal),
            ]
        }
        stats.append(Stat(label: "Latency", value: latency.map(Format.latency) ?? dash,
                          tone: latency.map { $0 >= 100 ? .danger : $0 >= 40 ? .warning : .normal } ?? .normal))

        return ProviderRow(
            id: p.latency,
            name: p.name,
            status: status,
            statusText: ponState.isEmpty ? text : "\(text) · \(ponState)",
            ip: ip,
            ipPublic: Format.isPublicIp(ip),
            ponMode: ponMode,
            ponRates: Format.ponRates(ponMode),
            down: bits(p.rx).map(Format.bitRate) ?? dash,
            up: bits(p.tx).map(Format.bitRate) ?? dash,
            stats: stats)
    }
}

private extension ProviderRow {
    /// cheap equality so SwiftUI only re-renders when something visible changed
    var signature: String {
        ([id, name, "\(status)", statusText, ip, ponMode, down, up] + stats.map { "\($0.value)\($0.tone)" })
            .joined(separator: "|")
    }
}
