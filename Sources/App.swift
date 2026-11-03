import AppKit
import Combine
import SwiftUI

let bundleId = "cloud.qoxi.netwidget"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let snapshotPath: String?
    private var client: HAClient?
    private var panel: DesktopPanel?
    private var host: DesktopHostingView<AnyView>?
    private var resize: AnyCancellable?

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
            WidgetView(store: store)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        )
        let host = DesktopHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.menuProvider = { [weak self] in self?.menu() }
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
    }

    /// grow/shrink with the content but keep the top edge where the user put it
    private func fitPanel() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        guard size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
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

    // MARK: --snapshot <png>: render once with live data, for checking the layout headless

    private func snapshot(to path: String) {
        Task { @MainActor in
            for _ in 0..<40 where store.link != .live || store.rows.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            // subscribe_entities sends its first full batch right after the result
            try? await Task.sleep(for: .seconds(1.5))
            let view = WidgetView(store: store)
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

final class DesktopHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
