import Foundation

/// A printer as Bambuddy knows it. Names and models follow Bambuddy; `name` can be changed in Bambu Bar.
struct PrinterConfig: Codable, Equatable {
    /// The printer's IP address as Bambuddy has it; shown, never connected to.
    var host: String
    var serial: String
    var name: String
    /// Bambuddy's model ("X1C", "P1S") or a model id ("N7").
    var modelCode: String
    /// The printer's id in Bambuddy's API.
    var bambuddyID: Int = 0
    /// The name Bambuddy has for it, to tell whether `name` was changed in Bambu Bar.
    var bambuddyName: String?

    var modelName: String { PrinterModel.name(for: modelCode, serial: serial) }
    var model: PrinterModel? { PrinterModel.find(code: modelCode, serial: serial) }
}

/// Follows one printer through the Bambuddy server: the full status from the REST API, WebSocket pushes merged
/// over it (they carry only some fields) and a poll every so often for what isn't pushed (time left, errors).
/// Commands go to Bambuddy, which passes them on to the printer.
@MainActor
final class PrinterConnection {
    enum Phase: Equatable {
        case idle
        case connecting
        case online
        case offline(String)
        /// Bambuddy rejected the API key.
        case unauthorized
        case certificate(String)
        /// macOS keeps Bambu Bar off the local network, where the Bambuddy server is.
        case localNetworkDenied
    }

    var onPhase: ((Phase) -> Void)?
    /// The status, and whether the job ended because someone stopped it.
    var onStatus: ((PrinterStatus, Bool) -> Void)?
    /// Any update from Bambuddy, changed or not.
    var onHeartbeat: (() -> Void)?
    /// The outcome of a command: command name, success, reason.
    var onAck: ((String, Bool, String?) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }

    private var config: PrinterConfig?
    private var hub: BambuddyHub?
    private var serverPhase: Phase = .idle
    /// Why the last request for this printer failed, when the server itself is fine.
    private var failure: BambuddyError?
    /// The latest status, REST and WebSocket merged.
    private var document: [String: Any] = [:]
    private var lastStatus: PrinterStatus?
    private var poller: Task<Void, Never>?

    func start(_ config: PrinterConfig, hub: BambuddyHub) {
        stop()
        self.config = config
        self.hub = hub
        phase = .connecting
        hub.register(config.bambuddyID, data: { [weak self] data in self?.pushed(data) },
                     phase: { [weak self] phase in self?.serverPhaseChanged(phase) })
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                // Pushes cover most changes; the poll catches the rest (time left, errors, Wi-Fi).
                try? await Task.sleep(for: .seconds(self.hub?.isLive == true ? 30 : 10))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        if let config { hub?.unregister(config.bambuddyID) }
        hub = nil
        config = nil
        failure = nil
        lastStatus = nil
        document = [:]
        phase = .idle
    }

    /// Asks the printer for a full report and fetches the result (after wake, or when the person clicks refresh).
    func refresh() {
        guard let config, let hub else { return }
        Task { [weak self] in
            try? await hub.client.refresh(config.bambuddyID)
            // The printer answers a refresh within a second or two.
            try? await Task.sleep(for: .seconds(1.5))
            await self?.poll()
        }
    }

    // MARK: - Commands

    func pause() { send("pause", "print/pause") }
    func resume() { send("resume", "print/resume") }
    func stopPrint() { send("stop", "print/stop") }
    func setSpeed(_ level: SpeedLevel) { send("print_speed", "print-speed", [URLQueryItem(name: "mode", value: "\(level.rawValue)")]) }
    func setChamberLight(_ on: Bool) { send("ledctrl", "chamber-light", [URLQueryItem(name: "on", value: on ? "true" : "false")]) }

    private func send(_ command: String, _ path: String, _ query: [URLQueryItem] = []) {
        guard let config, let hub else { return }
        let id = config.bambuddyID
        Task { [weak self] in
            do {
                try await hub.client.command(id, path, query: query)
                self?.onAck?(command, true, nil)
                // The printer takes a moment to report the change.
                try? await Task.sleep(for: .seconds(1.5))
                await self?.poll()
            } catch let error as BambuddyError {
                self?.onAck?(command, false, Self.reason(error))
                hub.report(error)
            } catch {
                self?.onAck?(command, false, error.localizedDescription)
            }
        }
    }

    private static func reason(_ error: BambuddyError) -> String {
        switch error {
        case .forbidden:
            return String(localized: "This API key can't control printers. Turn on Control for it in Bambuddy → Settings → API Keys.")
        case .notConnected:
            return String(localized: "Bambuddy isn't connected to the printer right now.")
        default:
            return error.message
        }
    }

    // MARK: - Status

    private func poll() async {
        guard let config, let hub else { return }
        do {
            let status = try await hub.client.status(config.bambuddyID)
            guard self.config?.bambuddyID == config.bambuddyID else { return }
            failure = nil
            // The REST status is complete, so it replaces what pushes merged in.
            document = status
            received()
        } catch let error as BambuddyError {
            guard self.config?.bambuddyID == config.bambuddyID else { return }
            switch error {
            case .unauthorized, .certificate, .localNetworkDenied, .unreachable:
                hub.report(error)
            case .forbidden, .notConnected, .server:
                failure = error
                updatePhase()
            }
        } catch {
            failure = .unreachable(error.localizedDescription)
            updatePhase()
        }
    }

    /// A WebSocket push: some of the status fields, merged over the rest as Bambuddy's own web page does.
    private func pushed(_ data: [String: Any]) {
        guard config != nil else { return }
        document.merge(data) { _, new in new }
        received()
    }

    private func received() {
        onHeartbeat?()
        updatePhase()
        guard phase == .online else { return }
        publishStatus()
    }

    private func serverPhaseChanged(_ phase: Phase) {
        serverPhase = phase
        updatePhase()
    }

    private func updatePhase() {
        guard config != nil else { return }
        switch serverPhase {
        case .unauthorized, .certificate, .localNetworkDenied, .offline:
            phase = serverPhase
            return
        default:
            break
        }
        if let failure {
            phase = .offline(failure.message)
        } else if document["state"] == nil {
            phase = .connecting
        } else if document["connected"] as? Bool == false {
            phase = .offline(String(localized: "Bambuddy can't reach this printer. Check that it's on and connected to the network."))
        } else {
            phase = .online
        }
    }

    private func publishStatus() {
        guard let config else { return }
        var status = BambuddyParser.status(from: document, model: config.model)
        if let last = lastStatus {
            // Keep the timestamp the remaining time was measured at, so the ETA doesn't drift between updates.
            var same = status
            same.updatedAt = last.updatedAt
            if same == last { return }
            if status.remainingMinutes == last.remainingMinutes && status.progress == last.progress && status.state == last.state {
                status.updatedAt = last.updatedAt
            }
        }
        lastStatus = status
        onStatus?(status, BambuddyParser.wasCanceled(document))
    }
}
