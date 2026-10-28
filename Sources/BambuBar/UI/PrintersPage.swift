import AppKit
import SwiftUI

/// The Bambuddy server, its printers and the current printer's details, separate from application preferences.
struct PrintersPage: View {
    @Environment(PrinterStore.self) private var store

    @State private var name = ""
    @State private var confirmDisconnect = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Printers")

            SettingsGroup("Bambuddy server", symbol: "server.rack") {
                if let url = store.serverURL {
                    SettingsRow("Address") { Text(url.absoluteString).foregroundStyle(.secondary).textSelection(.enabled) }
                    SettingsRow("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(store.serverPhase == .online ? Palette.accent : Palette.paused).frame(width: 7, height: 7)
                            Text(store.serverSummary).foregroundStyle(.secondary)
                        }
                    }
                    if let detail = store.serverDetail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        Button("Open Bambuddy") { NSWorkspace.shared.open(url) }
                        Spacer()
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                        Button("Change…") { MainWindow.changeServer() }
                    }
                } else {
                    HStack {
                        Text("No Bambuddy server set up yet.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Up…") { MainWindow.show(.overview) }
                    }
                }
            }

            SettingsGroup("Printers", symbol: "printer.dotmatrix.fill") {
                ForEach(store.sessions) { session in
                    printerRow(session)
                    Divider()
                }
                Text(store.isConfigured
                     ? "Every printer Bambuddy has. Printers added or removed there show up or disappear here."
                     : "Printers you add in Bambuddy show up here.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let config = store.config {
                SettingsGroup(store.hasMultiplePrinters ? "\(config.name)" : "Printer", symbol: "printer.fill") {
                    SettingsRow("Name") {
                        HStack(spacing: 8) {
                            if name != config.name {
                                Button("Revert") { name = config.name }.controlSize(.small)
                                Button("Save") { store.rename(config.serial, to: name) }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                    .tint(Palette.accentDeep)
                                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            TextField("Name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit { store.rename(config.serial, to: name) }
                        }
                    }
                    if let bambuddyName = store.bambuddyName(for: config.serial) {
                        HStack {
                            Text("Bambuddy calls it \u{201C}\(bambuddyName)\u{201D}. This name is only used in Bambu Bar.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use \u{201C}\(bambuddyName)\u{201D}") { store.rename(config.serial, to: bambuddyName) }
                                .controlSize(.small)
                        }
                    }
                    SettingsRow("Model") { Text("Bambu Lab \(config.modelName)").foregroundStyle(.secondary) }
                    SettingsRow("Serial number") { Text(config.serial).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !config.host.isEmpty {
                        SettingsRow("IP address") { Text(config.host).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    SettingsRow("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(store.isOnline ? Palette.accent : Palette.paused).frame(width: 7, height: 7)
                            Text(store.linkSummary).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsGroup("Controls", symbol: "slider.horizontal.3") {
                SettingsToggle("Ask before stopping a print", isOn: $store.confirmStop)
                Text("Controls go through Bambuddy. They need an API key with **Control printer** turned on, and pause, stop and speed changes also need **LAN Only** mode with **Developer Mode** on the printer (Settings → Network on its screen).")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { name = store.config?.name ?? "" }
        .onChange(of: store.config) { name = store.config?.name ?? "" }
        .alert("Disconnect from Bambuddy?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { store.disconnectServer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambu Bar stops showing the server's printers and removes the API key from your keychain. Print history stays.")
        }
    }

    private func printerRow(_ session: PrinterSession) -> some View {
        let isCurrent = session.id == store.current?.id
        return HStack(spacing: 12) {
            PrinterArt(status: session.status, model: session.config.modelName, dimmed: !session.isOnline, animated: false)
                .frame(width: 28, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.config.name).font(.system(size: 12.5, weight: .semibold))
                    if store.hasMultiplePrinters && session.id == store.menuBarSession?.id {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Shown in the menu bar")
                    }
                }
                Text("Bambu Lab \(session.config.modelName) · \(session.config.host)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                SessionDot(session: session)
                Text(session.shortState).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if store.hasMultiplePrinters {
                Button(isCurrent ? "Showing" : "Show") { store.select(session.id) }
                    .controlSize(.small)
                    .disabled(isCurrent)
            }
        }
    }
}
