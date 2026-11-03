import AppKit
import Combine
import SwiftUI

let bundleId = "cloud.qoxi.netwidget"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let hitMap = HitMap()
    private let snapshotPath: String?
    private var client: HAClient?
    private var panel: DesktopPanel?
    private var host: DesktopHostingView<AnyView>?
    private var resize: AnyCancellable?
    private var detail: (panel: DetailPanel, host: TrackingHostingView<AnyView>, model: DetailModel, watch: AnyCancellable)?
    private var monitors: [Any] = []

    init(snapshotPath: String?) {
        self.snapshotPath = snapshotPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let headless = snapshotPath != nil || CommandLine.arguments.contains("--watch")
        if !headless,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
            NSApp.terminate(nil)
            return
        }
        // LAN first, cloud (Nabu Casa) second; written by install.sh from HA_URL / HA_CLOUD_URL
        let bases = ["haURL", "haCloudURL"].compactMap { UserDefaults.standard.string(forKey: $0).flatMap(URL.init(string:)) }
        if bases.isEmpty {
            store.setLink(.offline(since: Date(), reason: "haURL not set"))
        } else if let token = keychainToken() {
            client = HAClient(bases: bases, token: token, store: store)
            client?.connect()
        } else {
            store.setLink(.offline(since: Date(), reason: "no token in Keychain (\(bundleId))"))
        }

        if let snapshotPath { return snapshot(to: snapshotPath) }
        if CommandLine.arguments.contains("--watch") { return watch() }
        showPanel()
        // sockets don't survive sleep; the ping would notice after ~40 s, this is instant
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.client?.reconnectNow() }
        }
    }

    // MARK: panel

    private func showPanel() {
        let root = AnyView(
            WidgetView(store: store, hitMap: hitMap)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        )
        let host = DesktopHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.menuProvider = { [weak self] in self?.menu() }
        host.onClick = { [weak self] point in self?.click(at: point) }
        host.onDragStart = { [weak self] in self?.closeDetail() }
        let panel = DesktopPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize))
        panel.contentView = host
        if !panel.setFrameUsingName("NetWidget"), let screen = NSScreen.main?.visibleFrame {
            let size = host.fittingSize
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        panel.setFrameAutosaveName("NetWidget")
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
        resize = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.fitPanel() }
        }
        if let spot = option("--click")?.split(separator: ",").compactMap({ Double($0) }), spot.count == 2 {
            debugClick(CGPoint(x: spot[0], y: spot[1]))
        }
    }

    /// --click x,y (widget coordinates, top-left): exercise hit-testing and the detail panel without a mouse
    private func debugClick(_ point: CGPoint) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            for (target, frame) in hitMap.frames.sorted(by: { $0.value.minY == $1.value.minY ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY }) {
                print("target", target.kind, target.row.suffix(22), "frame", frame.integral)
            }
            print("click", point, "→", hitMap.target(at: point).map { "\($0.kind)" } ?? "nothing")
            click(at: point)
            try? await Task.sleep(for: .seconds(3))
            print("widget", panel?.frame ?? .zero, "detail", detail?.panel.frame ?? .zero, "key", detail?.panel.isKeyWindow ?? false,
                  "points", detail?.model.series.map(\.points.count) ?? [], "loaded", detail?.model.loaded ?? false)
            fflush(stdout)
        }
    }

    /// grow/shrink with the content but keep the top edge where the user put it
    private func fitPanel() {
        guard let panel, let host else { return }
        fit(panel, to: host.fittingSize)
    }

    private func fit(_ window: NSWindow, to size: NSSize) {
        guard size != window.frame.size else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Reconnect", #selector(reconnect)),
            ("Open Network dashboard", #selector(openDashboard)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NetWidget", action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    @objc private func reconnect() { client?.reconnectNow() }

    @objc private func openDashboard() {
        guard let base = client?.currentBase else { return }
        NSWorkspace.shared.open(base.appendingPathComponent("dashboard-home-ios/network"))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: detail (click on a tile / the rates / a provider's name)

    private func click(at point: CGPoint) {
        guard let target = hitMap.target(at: point) else { return closeDetail() }
        if detail?.model.target == target { return closeDetail() }
        openDetail(target, anchor: hitMap.frames[target] ?? .zero)
    }

    private func openDetail(_ target: DetailTarget, anchor: CGRect) {
        closeDetail()
        guard let client, let widget = panel, let model = DetailModel(target: target, store: store, client: client) else { return }
        let root = AnyView(
            DetailView(model: model, openInHA: { [weak self, weak model] in
                guard let self, let model, let base = self.client?.currentBase else { return }
                NSWorkspace.shared.open(model.historyURL(base: base))
                self.closeDetail()
            })
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        let host = TrackingHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.onMouse = { [weak model] point in
            guard let model else { return }
            let plot = model.plotFrame.insetBy(dx: 0, dy: -8)
            model.hover = point.flatMap { plot.contains($0) ? model.hoverDate(atX: $0.x) : nil }
        }
        let size = host.fittingSize
        let panel = DetailPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = host

        // beside the widget, top aligned with the clicked row; flip left when there's no room
        let screen = (widget.screen ?? NSScreen.main)?.visibleFrame ?? widget.frame
        let wf = widget.frame
        var x = wf.maxX + 12
        if x + size.width > screen.maxX { x = wf.minX - 12 - size.width }
        let top = min(wf.maxY - anchor.minY + 16, screen.maxY)
        let y = max(top - size.height, screen.minY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)

        let watch = model.objectWillChange.sink { [weak self, weak host, weak panel] in
            DispatchQueue.main.async {
                guard let self, let host, let panel else { return }
                self.fit(panel, to: host.fittingSize)
            }
        }
        detail = (panel, host, model, watch)
        model.start()
        installMonitors()
    }

    private func closeDetail() {
        guard let d = detail else { return }
        detail = nil
        d.model.stop()
        d.panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func installMonitors() {
        // clicks in other apps / on the desktop close it, like a popover
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeDetail() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.closeDetail() }
            return nil
        }) { monitors.append(m) }
    }

    // MARK: --watch: no window, print every visible change (debugging the live feed)

    private func watch() {
        resize = store.$rows.sink { rows in
            let time = Date().formatted(date: .omitted, time: .standard)
            for r in rows {
                print(time, r.name, r.statusText, "↓\(r.down) ↑\(r.up)", r.stats.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
            }
            fflush(stdout)
        }
    }

    // MARK: --snapshot <png> [--detail <isp>:<rx_power|tx_power|optic_temperature|latency|rates|status>:<1h|24h|7d> [--hover <0…1>]]
    // renders once with live data, for checking the layout headless

    private func snapshot(to path: String) {
        Task { @MainActor in
            for _ in 0..<40 where store.link != .live || store.rows.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            // subscribe_entities sends its first full batch right after the result
            try? await Task.sleep(for: .seconds(1.5))
            var content = AnyView(WidgetView(store: store))
            if let spec = option("--detail")?.split(separator: ":").map(String.init), spec.count == 3,
               let client, let row = store.rows.first(where: { $0.name.lowercased() == spec[0].lowercased() }) {
                let kind: DetailKind = spec[1] == "rates" ? .rates : spec[1] == "status" ? .status : .metric(spec[1])
                guard let model = DetailModel(target: DetailTarget(row: row.id, kind: kind), store: store, client: client) else { exit(2) }
                model.range = TimeRange(rawValue: spec[2]) ?? .day
                await model.fetch()
                if let frac = option("--hover").flatMap(Double.init) {
                    let w = model.window
                    model.hover = w.lowerBound.addingTimeInterval(w.upperBound.timeIntervalSince(w.lowerBound) * frac)
                }
                content = AnyView(DetailView(model: model))
            }
            let view = content
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.11).opacity(0.92)))
                .padding(24)
                .background(LinearGradient(
                    colors: [Color(red: 0.16, green: 0.22, blue: 0.45), Color(red: 0.32, green: 0.16, blue: 0.42)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(store.rows.isEmpty ? 1 : 0)
        }
    }

    private func option(_ name: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}

/// Token lives in the login Keychain. It's read through /usr/bin/security (the
/// item's creator, so it's on the ACL) — an ad-hoc signed app gets a new code
/// hash on every rebuild and would otherwise re-prompt for Keychain access.
private func keychainToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", bundleId, "-a", "ha", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

final class DesktopPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // above the desktop icons, below every app window — where macOS widgets live
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// floats over app windows; key (for Esc) without activating the app, like Spotlight
final class DetailPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Click = no movement between down and up → hit-tested by the caller; any drag
/// beyond 3 pt moves the window instead.
final class DesktopHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?
    var onClick: ((CGPoint) -> Void)?
    var onDragStart: (() -> Void)?
    private var down: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        down = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let window else { return }
        let p = NSEvent.mouseLocation
        if !dragging {
            guard hypot(p.x - down.mouse.x, p.y - down.mouse.y) >= 3 else { return }
            dragging = true
            onDragStart?()
        }
        window.setFrameOrigin(NSPoint(x: down.origin.x + p.x - down.mouse.x, y: down.origin.y + p.y - down.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        if dragging {
            window?.saveFrame(usingName: "NetWidget")
            return
        }
        onClick?(topLeft(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports the mouse in SwiftUI (top-left) coordinates; `.activeAlways` keeps
/// it working while the app is inactive, which SwiftUI's own hover is not.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouse: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouse?(topLeft(event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouse?(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSView {
    func topLeft(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }
}
