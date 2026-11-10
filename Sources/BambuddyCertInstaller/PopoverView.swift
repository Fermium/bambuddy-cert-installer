import AppKit
import CertKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: Model
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header
            if model.needsConfirming || model.changed { trustCard }
            if !model.rows.isEmpty || model.cert != nil { slicers }
            if let note = model.note {
                Label(note, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        .frame(width: 320)
        .animation(.snappy, value: model.rows.map(\.state))
        .animation(.snappy, value: model.trusted)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: model.allGood ? "checkmark.shield.fill" : model.cert == nil ? "shield.slash" : "exclamationmark.shield.fill")
                .font(.system(size: 44)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.allGood ? .green : model.cert == nil ? .secondary : Color.orange)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.headline)
            HStack(spacing: 4) {
                if model.checking { ProgressView().controlSize(.mini) }
                Text(subtitle)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        if model.cert == nil { return model.checking && model.lastCheck == nil ? "Looking for Bambuddy…" : "Bambuddy not found" }
        if model.needsConfirming { return "Check Bambuddy's certificate" }
        if model.changed { return "Bambuddy's certificate changed" }
        if model.allGood { return "Your slicers trust Bambuddy" }
        return "A slicer needs the certificate"
    }

    private var subtitle: String {
        guard let host = model.bambuddy?.address.host() else { return "Searching this network" }
        return "Bambuddy at \(host)"
    }

    // MARK: Trust

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.changed ? "Only trust the new certificate if you changed it in Bambuddy." : "Check this matches Bambuddy's Settings › Virtual Printer page.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let cert = model.cert {
                Text(cert.fingerprint).font(.caption2.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            Button(model.changed ? "Trust New Certificate" : "Trust Certificate") { model.trust() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    // MARK: Slicers

    private var slicers: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                Text("No OrcaSlicer or Bambu Studio found.").font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider().padding(.leading, 52) }
                SlicerRow(model: model, row: row)
            }
        }
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button { Task { await model.refresh() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                .disabled(model.checking)
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }.help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

private struct SlicerRow: View {
    @ObservedObject var model: Model
    let row: Model.Row

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.slicer.app.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.slicer.name)
                    if !row.version.isEmpty { Text(row.version).foregroundStyle(.tertiary) }
                }
                .font(.callout)
                Label(status, systemImage: symbol).font(.caption).foregroundStyle(color).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 6)
            if model.busy.contains(row.id) || row.state == nil {
                ProgressView().controlSize(.small)
            } else if row.state?.trusted == false {
                Button("Add") { model.add(row) }.disabled(!model.ready || row.running)
            } else if row.state?.canUndo == true {
                Menu {
                    Button("Undo", role: .destructive) { model.undo(row) }.disabled(row.running)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Undo")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var status: String {
        guard let state = row.state else { return "Checking…" }
        if model.busy.contains(row.id) { return "Re-signing…" }
        if !state.signatureValid { return "Signature broken: macOS may not open it" }
        if state.trusted { return "Trusts Bambuddy" }
        return row.running ? "Quit it first" : "Not trusted yet"
    }

    private var symbol: String {
        guard let state = row.state, !model.busy.contains(row.id) else { return "clock" }
        if !state.signatureValid { return "xmark.seal" }
        return state.trusted ? "checkmark.seal.fill" : "seal"
    }

    private var color: Color {
        guard let state = row.state, !model.busy.contains(row.id) else { return .secondary }
        if !state.signatureValid { return .red }
        return state.trusted ? .green : .orange
    }
}
