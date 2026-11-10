import CertKit
import SwiftUI

@main
struct BambuddyCertInstallerApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.needsAttention ? "exclamationmark.shield" : "checkmark.shield")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bambuddy
            if model.cert != nil { Divider(); slicers }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                TextField("Address", text: $model.manualAddress, prompt: Text("Bambuddy address, or empty to search"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveAddress() }
                Button("Check Again") { Task { await model.refresh() } }.disabled(model.checking)
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder private var bambuddy: some View {
        HStack {
            Text("Bambuddy").font(.headline)
            Spacer()
            if model.checking { ProgressView().controlSize(.small) }
            Text(model.bambuddy?.address.host() ?? "Not found").foregroundStyle(.secondary)
        }
        if let cert = model.cert {
            VStack(alignment: .leading, spacing: 4) {
                Text(cert.fingerprint).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let expires = cert.expires {
                    Text("\(cert.commonName ?? "Certificate"), until \(expires.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.needsConfirming {
                Text("Check this matches the fingerprint in Bambuddy under Settings › Virtual Printer, then trust it.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Trust This Certificate") { model.trust() }
            } else if model.changed {
                Text("Bambuddy's certificate changed. Only trust the new one if you changed it in Bambuddy.")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Trust New Certificate") { model.trust() }
            }
        }
    }

    @ViewBuilder private var slicers: some View {
        if model.rows.isEmpty {
            Text("No OrcaSlicer or Bambu Studio found.").foregroundStyle(.secondary)
        }
        ForEach(model.rows) { row in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.slicer.name)
                    Text(status(row)).font(.caption).foregroundStyle(row.state?.trusted == true && row.state?.signatureValid == true ? .secondary : Color.orange)
                }
                Spacer()
                if model.busy == row.id {
                    ProgressView().controlSize(.small)
                } else {
                    if row.state?.canUndo == true { Button("Undo") { model.undo(row) } }
                    if row.state?.trusted == false { Button("Add") { model.add(row) }.disabled(!model.ready) }
                }
            }
        }
    }

    private func status(_ row: Model.Row) -> String {
        guard let state = row.state else { return "Checking…" }
        if !state.signatureValid { return "Its signature is broken, so macOS may not open it" }
        if state.trusted { return "Trusts Bambuddy" }
        return row.running ? "Doesn't trust Bambuddy yet. Quit it first." : "Doesn't trust Bambuddy yet"
    }
}
