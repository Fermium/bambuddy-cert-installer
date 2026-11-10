import AppKit
import Combine
import SwiftUI

/// The menu bar shield: a click opens the popover, a right-click the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = Model()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private lazy var settings = SettingsWindowController(model: model)
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let folder = Snapshot.folder {
            statusItem.isVisible = false
            Task { await Snapshot.run(model, to: folder) }
            return
        }
        if let button = statusItem.button {
            button.action = #selector(clicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let host = NSHostingController(rootView: PopoverView(model: model, openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        watch = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }
        updateIcon()
        // -settings and -popover open those at launch.
        let args = CommandLine.arguments
        if args.contains("-settings") { openSettings() }
        if args.contains("-popover") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.showPopover() } } }
    }

    private func updateIcon() {
        let good = model.allGood
        let image = NSImage(systemSymbolName: good ? "checkmark.shield" : "exclamationmark.shield", accessibilityDescription: good ? "Slicers trust Bambuddy" : "Bambuddy Cert Installer needs attention")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Check Again", action: #selector(checkAgain), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Bambuddy Cert Installer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        Task { await model.reloadSlicers() }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func checkAgain() { Task { await model.refresh() } }
    @objc private func openSettingsItem() { openSettings() }

    private func openSettings() {
        popover.performClose(nil)
        settings.show()
    }
}
