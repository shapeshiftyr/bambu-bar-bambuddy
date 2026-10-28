import SwiftUI

/// First run, or changing servers: the Bambuddy server's address and an API key. Every printer Bambuddy has shows
/// up once they check out.
struct SetupPage: View {
    @Environment(PrinterStore.self) private var store
    @Environment(Navigation.self) private var navigation

    @State private var address = ""
    @State private var apiKey = ""
    /// App Review wants Open at Login to be the person's own choice, so the App Store build starts unchecked.
    #if APP_STORE
        @State private var openAtLogin = false
    #else
        @State private var openAtLogin = true
    #endif
    @State private var connecting = false
    /// Why the last Connect didn't work (no server there, key rejected…).
    @State private var problem: String?
    /// Connect worked but the server has no printers yet.
    @State private var empty = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if changing {
                PageHeader(title: "Bambuddy Server", subtitle: String(localized: "Bambu Bar shows every printer this server has.")) {
                    Button("Cancel") { navigation.changingServer = false }
                }
            } else {
                hero
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("1  Your Bambuddy server")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Server address", text: $address, prompt: Text(verbatim: "http://192.168.1.10:8000"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5))
                        .frame(maxWidth: 360)
                        .onSubmit { keyFocused = true }
                    Text("The address you open Bambuddy at in a browser, with its port. Both **http** and **https** work.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel(radius: 16, padding: 14)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("2  API key")
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text(verbatim: "bb_…"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(maxWidth: 360)
                        .focused($keyFocused)
                        .onSubmit(connect)
                    Text("In Bambuddy open **Settings → API Keys** and create a key. **Read status** is enough to watch your printers; turn on **Control printer** too for pause, resume, stop, speed and the chamber light. The key is kept in your keychain and only sent to your server.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                .panel(radius: 16, padding: 14)
            }

            if !changing {
                Toggle(isOn: $openAtLogin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open Bambu Bar at login").font(.system(size: 12.5, weight: .medium))
                        Text("It starts quietly in the menu bar, without a Dock icon.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .tint(Palette.accentDeep)
            }

            HStack(spacing: 12) {
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if connecting { ProgressView().controlSize(.small).tint(.white) }
                        Text(connecting ? "Connecting…" : "Connect")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(ControlButtonStyle(tint: Palette.accentDeep, prominent: true))
                .frame(width: 150)
                .disabled(!canConnect)
                .keyboardShortcut(.defaultAction)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.paused)
                        .fixedSize(horizontal: false, vertical: true)
                } else if empty || (store.hasServer && store.serverPhase == .online && !store.isConfigured) {
                    Label("Connected. Bambuddy has no printers yet; add them there and they show up here.", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.localNetworkBlocked {
                localNetworkNotice
            }
        }
        .onAppear {
            address = store.serverURL?.absoluteString ?? ""
            apiKey = store.serverAPIKey ?? ""
        }
        .onChange(of: address) { problem = nil; empty = false }
        .onChange(of: apiKey) { problem = nil; empty = false }
    }

    /// The server is on the local network and macOS keeps the app off it: say why, and where the switch is.
    private var localNetworkNotice: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.paused)
            Text(LocalNetwork.advice)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Settings") { LocalNetwork.openSettings() }
                .controlSize(.small)
        }
        .panel(radius: 14, padding: 12, tint: Palette.paused)
    }

    private var hero: some View {
        HStack(spacing: 24) {
            PrinterArt(status: .sample, animated: true)
                .frame(width: 150, height: 180)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Bambu Bar")
                    .font(.system(size: 28, weight: .bold))
                Text("Your printers' progress, temperatures and filament, one click away in the menu bar. Bambu Bar gets them from your Bambuddy server, so every printer Bambuddy manages shows up here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    /// Changing the server of a set-up app rather than setting it up for the first time.
    private var changing: Bool { store.isConfigured }

    private var canConnect: Bool {
        !connecting && !address.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func connect() {
        guard canConnect else { return }
        guard let url = BambuddyClient.normalize(address) else {
            problem = String(localized: "Enter the server's address, like http://192.168.1.10:8000.")
            return
        }
        let firstTime = !store.isConfigured
        connecting = true
        problem = nil
        empty = false
        Task {
            defer { connecting = false }
            do {
                let count = try await store.connectServer(url: url, apiKey: apiKey)
                address = url.absoluteString
                guard count > 0 else {
                    empty = true
                    return
                }
                navigation.changingServer = false
                if firstTime && openAtLogin && !LoginItem.shared.isEnabled && !store.isDemo { LoginItem.shared.setEnabled(true) }
            } catch let error as BambuddyError {
                if case .forbidden = error {
                    problem = String(localized: "This API key can't read printers. Turn on Read status for it in Bambuddy → Settings → API Keys.")
                } else {
                    problem = error.message
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
