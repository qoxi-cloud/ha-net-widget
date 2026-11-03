import AppKit

let args = CommandLine.arguments
let snapshotPath = args.firstIndex(of: "--snapshot").map { args.indices.contains($0 + 1) ? args[$0 + 1] : "netwidget.png" }

MainActor.assumeIsolated {
    let delegate = AppDelegate(snapshotPath: snapshotPath)
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
