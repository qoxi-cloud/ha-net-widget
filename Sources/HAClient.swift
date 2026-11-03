import Foundation

struct HAError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal HA websocket client: auth → get_states (discovery) → subscribe_entities
/// for just the ~30 entities the widget shows. Tries the LAN first, then Nabu
/// Casa; while on the cloud it probes the LAN and moves back as soon as it
/// answers. HA-level pings catch dead sockets (sleep, VLAN hiccups), which
/// URLSession would otherwise wait on forever.
@MainActor
final class HAClient {
    private let bases: [URL]
    private let token: String
    private let store: Store
    private let session = URLSession(configuration: .ephemeral)

    private var task: URLSessionWebSocketTask?
    private var current = 0
    private var authed = false
    private var generation = 0
    private var nextId = 1
    private var statesId = -1
    private var subscribeId = -1
    private var timers: [Timer] = []
    private var pongTimer: Timer?
    private var backoff: TimeInterval = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]

    var currentBase: URL { bases[current] }

    init(bases: [URL], token: String, store: Store) {
        self.bases = bases
        self.token = token
        self.store = store
    }

    func connect() {
        teardown()
        generation += 1
        nextId = 1
        authed = false
        var c = URLComponents(url: bases[current], resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/api/websocket"
        let t = session.webSocketTask(with: c.url!)
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
        receive(generation)
        // the LAN answers in milliseconds; away from home don't sit in a dead handshake
        let gen = generation
        schedule(current == 0 ? 4 : 15) { [weak self] in
            guard let self, gen == self.generation, !self.authed else { return }
            self.fail("connect timeout")
        }
    }

    /// wake from sleep / menu: start over from the LAN, no backoff
    func reconnectNow() {
        backoff = 1
        current = 0
        connect()
    }

    /// one-shot command on the live socket (history, statistics); fails fast when offline
    func request(_ type: String, _ payload: [String: Any]) async throws -> Any {
        guard authed, task != nil else { throw HAError(message: "Home Assistant is offline") }
        return try await withCheckedThrowingContinuation { continuation in
            let id = command(type, payload)
            pending[id] = continuation
            let gen = generation
            schedule(20) { [weak self] in
                guard let self, gen == self.generation, let c = self.pending.removeValue(forKey: id) else { return }
                c.resume(throwing: HAError(message: "Home Assistant did not answer"))
            }
        }
    }

    private func teardown() {
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resume(throwing: HAError(message: "connection lost")) }
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        pongTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    @discardableResult
    private func schedule(_ interval: TimeInterval, repeats: Bool = false, _ body: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in body() }
        }
        timers.removeAll { !$0.isValid }
        timers.append(t)
        return t
    }

    private func fail(_ reason: String, retryAfter: TimeInterval? = nil) {
        teardown()
        // never got in on this endpoint → try the next one right away
        if !authed, current + 1 < bases.count {
            current += 1
            return connect()
        }
        store.setLink(.offline(since: Date(), reason: reason))
        current = 0
        let delay = retryAfter ?? backoff
        backoff = min(backoff * 2, 60)
        schedule(delay) { [weak self] in self?.connect() }
    }

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.fail(error.localizedDescription)
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(Data(s.utf8))
                    case .data(let d): self.handle(d)
                    @unknown default: break
                    }
                    if gen == self.generation { self.receive(gen) }
                }
            }
        }
    }

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        let gen = generation
        task?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func command(_ type: String, _ extra: [String: Any] = [:]) -> Int {
        let id = nextId
        nextId += 1
        send(extra.merging(["id": id, "type": type]) { $1 })
        return id
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        let messages = (obj as? [[String: Any]]) ?? [obj as? [String: Any]].compactMap { $0 }
        messages.forEach(dispatch)
    }

    private func dispatch(_ m: [String: Any]) {
        let id = m["id"] as? Int ?? -1
        if m["type"] as? String == "result", let continuation = pending.removeValue(forKey: id) {
            if m["success"] as? Bool == true {
                continuation.resume(returning: m["result"] ?? NSNull())
            } else {
                let message = (m["error"] as? [String: Any])?["message"] as? String ?? "request failed"
                continuation.resume(throwing: HAError(message: message))
            }
            return
        }
        switch m["type"] as? String {
        case "auth_required":
            send(["type": "auth", "access_token": token])
        case "auth_ok":
            authed = true
            backoff = 1
            statesId = command("get_states")
            startPings()
            if current > 0 { startLanProbe() }
        case "auth_invalid":
            // a revoked token won't fix itself; don't hammer HA (it bans IPs on repeated failures)
            fail("token rejected", retryAfter: 600)
        case "result" where id == statesId:
            guard m["success"] as? Bool == true, let list = m["result"] as? [[String: Any]] else {
                return fail("get_states failed")
            }
            var all: [String: EntityState] = [:]
            for s in list {
                guard let eid = s["entity_id"] as? String else { continue }
                all[eid] = EntityState(state: s["state"] as? String ?? "", attributes: s["attributes"] as? [String: Any] ?? [:])
            }
            let ids = store.load(all)
            if ids.isEmpty { return fail("no ISP entities found", retryAfter: 120) }
            subscribeId = command("subscribe_entities", ["entity_ids": ids])
        case "result" where id == subscribeId:
            if m["success"] as? Bool == true { store.setLink(.live, viaCloud: current > 0) } else { fail("subscribe failed") }
        case "event" where id == subscribeId:
            if let event = m["event"] as? [String: Any] { store.apply(event) }
        case "pong":
            pongTimer?.invalidate()
        default:
            break
        }
    }

    private func startPings() {
        schedule(30, repeats: true) { [weak self] in
            guard let self else { return }
            _ = self.command("ping")
            self.pongTimer?.invalidate()
            self.pongTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fail("ping timeout") }
            }
        }
    }

    /// on the cloud: any HTTP answer from the LAN address means we're home again
    private func startLanProbe() {
        schedule(60, repeats: true) { [weak self] in
            guard let self else { return }
            let gen = self.generation
            let request = URLRequest(url: self.bases[0].appendingPathComponent("api/"), timeoutInterval: 2)
            self.session.dataTask(with: request) { [weak self] _, response, _ in
                guard response is HTTPURLResponse else { return }
                Task { @MainActor in
                    guard let self, gen == self.generation, self.current > 0 else { return }
                    self.reconnectNow()
                }
            }.resume()
        }
    }
}
