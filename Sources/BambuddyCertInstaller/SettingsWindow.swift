import AppKit
import CertKit
import SwiftUI

/// A toolbar-style Settings window, one tab per pane, as in Peel Good Inc.
@MainActor
final class SettingsWindowController {
    private let model: Model
    private var window: NSWindow?

    init(model: Model) { self.model = model }

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab("General", "gearshape", GeneralPane(model: model)))
            tabs.addTabViewItem(tab("About", "info.circle", AboutView()))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

struct GeneralPane: View {
    @ObservedObject var model: Model
    @State private var typed = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $typed, prompt: Text("Find automatically"))
                    .onSubmit { save() }
                LabeledContent("Status") {
                    Text(model.bambuddy.map { "Found at \($0.address.host() ?? "")" } ?? (model.checking ? "Looking…" : "Not found"))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Check Again") { save() }.disabled(model.checking)
                }
            } header: {
                Text("Bambuddy")
            } footer: {
                Text("Leave it empty to find Bambuddy by its Virtual Printer on this network. Or type an address, such as bambuddy.lan or 192.168.1.50:8000.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Trusted Certificate") {
                if let trusted = model.trusted {
                    Text(trusted).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Forget") { model.forgetTrust() }
                    }
                } else {
                    Text("None yet. Trust Bambuddy's certificate from the menu bar.").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Add it again after a slicer updates", isOn: $model.fixAfterUpdates)
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.opensAtLogin = $0 }))
            } footer: {
                Text("Updates put back the slicer's own certificate file. Bambuddy Cert Installer adds the certificate again once the slicer is closed, for slicers you added it to.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Backups") {
                LabeledContent("Space used", value: model.backupSize)
                HStack {
                    Spacer()
                    Button("Show in Finder") { model.showBackups() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { typed = model.address }
    }

    private func save() {
        model.address = typed.trimmingCharacters(in: .whitespaces)
        Task { await model.refresh() }
    }
}

struct AboutView: View {
    @State private var showLicense = false

    static let companyURL = URL(string: "https://find-and-update.company-information.service.gov.uk/company/12425065")!
    static let issuesURL = URL(string: "https://github.com/Fermium/bambuddy-cert-installer/issues/new")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield.fill").font(.system(size: 72)).symbolRenderingMode(.hierarchical).foregroundStyle(.green)
            Text("Bambuddy Cert Installer").font(.title.weight(.semibold)).padding(.top, 12)
            Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)

            VStack(spacing: 2) {
                Text("© 2026 FERMIUM LTD")
                Link("Company number 12425065", destination: Self.companyURL).font(.callout)
            }
            .padding(.top, 18)

            Button("MIT License") { showLicense = true }.padding(.top, 14)
            Text("Not affiliated with Bambu Lab or Bambuddy.").font(.caption).foregroundStyle(.secondary).padding(.top, 10)

            Divider().frame(width: 260).padding(.vertical, 20)

            Text("Questions or problems?").font(.headline)
            Button {
                NSWorkspace.shared.open(Self.issuesURL)
            } label: {
                Label("Open an Issue on GitHub", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(30)
        .frame(width: 480, height: 440)
        .sheet(isPresented: $showLicense) { LicenseSheet() }
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT License\n\nCopyright (c) 2026 Fermium Ltd"

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 520, height: 400)
    }
}
