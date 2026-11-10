import AppKit
import SwiftUI

/// `-snapshot <folder>`: draws the popover and Settings offscreen into PNGs, light and dark, then quits.
/// Nothing appears on screen, so it needs no Screen Recording permission.
@MainActor
enum Snapshot {
    static var folder: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return nil }
        return URL(filePath: args[i + 1], directoryHint: .isDirectory)
    }

    static func run(_ model: Model, to folder: URL) async {
        // The model's own first check is already running: wait for it rather than start another.
        while model.lastCheck == nil || model.checking { try? await Task.sleep(for: .milliseconds(200)) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: look)!
            save(PopoverView(model: model, openSettings: {}), appearance, folder.appending(path: "popover-\(name).png"))
            save(GeneralPane(model: model), appearance, folder.appending(path: "settings-general-\(name).png"))
            save(AboutView(), appearance, folder.appending(path: "settings-about-\(name).png"))
        }
        NSApp.terminate(nil)
    }

    private static func save<V: View>(_ view: V, _ appearance: NSAppearance, _ file: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        window.orderOut(nil)
    }
}
