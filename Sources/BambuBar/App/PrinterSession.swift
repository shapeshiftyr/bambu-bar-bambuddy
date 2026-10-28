import Foundation
import Observation

/// One printer from the Bambuddy server: its connection, live status and the commands in flight.
/// `PrinterStore` owns the sessions and handles what spans printers (history, notifications, widgets).
@MainActor
@Observable
final class PrinterSession: Identifiable {
    /// The serial number, which never changes for a session.
    nonisolated let id: String
    var config: PrinterConfig
    private(set) var phase: PrinterConnection.Phase = .idle
    private(set) var status: PrinterStatus?
    /// Commands sent but not yet reflected in a report, so the controls respond immediately.
    private(set) var pendingLight: Bool?
    private(set) var pendingSpeed: SpeedLevel?
    /// False until the first report after connecting, so state already in progress doesn't notify.
    var hasBaseline = false
    /// When Bambuddy last sent anything about the printer, to the second ("Updated 3s ago").
    private(set) var lastHeard: Date?

    var onPhase: ((PrinterSession, PrinterConnection.Phase) -> Void)?
    var onStatus: ((PrinterSession, PrinterStatus?, PrinterStatus, Bool) -> Void)?
    var onAck: ((PrinterSession, String, Bool, String?) -> Void)?
    var onHeartbeat: ((PrinterSession) -> Void)?

    @ObservationIgnored private let connection = PrinterConnection()
    @ObservationIgnored private var demo: DemoDriver?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    init(config: PrinterConfig) {
        id = config.serial
        self.config = config
        connection.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        connection.onStatus = { [weak self] status, canceled in self?.received(status, canceled: canceled) }
        connection.onAck = { [weak self] command, ok, reason in
            guard let self else { return }
            if !ok { self.pendingLight = nil; self.pendingSpeed = nil }
            self.onAck?(self, command, ok, reason)
        }
        connection.onHeartbeat = { [weak self] in
            guard let self else { return }
            // Whole seconds are enough for the label and spare the UI an update per message.
            if self.lastHeard.map({ Date().timeIntervalSince($0) >= 1 }) ?? true { self.lastHeard = Date() }
            self.onHeartbeat?(self)
        }
    }

    // MARK: - Lifecycle

    func start(hub: BambuddyHub) {
        status = nil
        hasBaseline = false
        connection.start(config, hub: hub)
    }

    /// Runs a simulated printer instead of a connection (`--demo`).
    func startDemo(_ scenario: DemoDriver.Scenario, variant: Int) {
        let driver = DemoDriver(scenario: scenario, variant: variant)
        driver.onStatus = { [weak self] status, canceled in self?.received(status, canceled: canceled) }
        driver.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        demo = driver
        driver.start()
    }

    /// Shows a scripted status, as if the printer had reported it (README frames).
    func showDemoStatus(_ status: PrinterStatus) {
        received(status, canceled: false)
    }

    func stop() {
        connection.stop()
        phase = .idle
    }

    func refresh() { connection.refresh() }

    // MARK: - Derived

    /// A live status is on hand: connected, or briefly reconnecting after a drop.
    var isOnline: Bool { status != nil && (phase == .online || phase == .connecting) }
    var chamberLightOn: Bool { pendingLight ?? status?.chamberLightOn ?? false }
    var speed: SpeedLevel { pendingSpeed ?? status?.speed ?? .standard }

    var linkSummary: String {
        switch phase {
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .online: return String(localized: "Connected")
        case .offline: return String(localized: "Offline")
        case .unauthorized: return String(localized: "API key rejected")
        case .certificate: return String(localized: "Certificate not trusted")
        case .localNetworkDenied: return String(localized: "No local network access")
        }
    }

    var linkDetail: String? {
        switch phase {
        case .offline(let reason): return reason
        case .unauthorized: return BambuddyError.unauthorized.message
        case .certificate(let reason): return BambuddyError.certificate(reason).message
        case .localNetworkDenied: return LocalNetwork.advice
        default: return nil
        }
    }

    /// "Printing · 64%", "Ready", "Offline" — one line for menus and lists.
    var shortState: String {
        guard let s = status, isOnline else { return linkSummary }
        return s.state.isActive ? "\(s.state.title) · \(s.progress)%" : s.stateTitle
    }

    // MARK: - Commands

    func pause() { if let demo { demo.pause() } else { connection.pause() } }
    func resume() { if let demo { demo.resume() } else { connection.resume() } }
    func stopPrint() { if let demo { demo.stop() } else { connection.stopPrint() } }

    func toggleLight() {
        let on = !chamberLightOn
        pendingLight = on
        if let demo { demo.setLight(on) } else { connection.setChamberLight(on) }
        clearPendingSoon()
    }

    func setSpeed(_ level: SpeedLevel) {
        pendingSpeed = level
        if let demo { demo.setSpeed(level) } else { connection.setSpeed(level) }
        clearPendingSoon()
    }

    private func clearPendingSoon() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.pendingLight = nil
            self?.pendingSpeed = nil
        }
    }

    // MARK: - Updates

    private func phaseChanged(_ phase: PrinterConnection.Phase) {
        self.phase = phase
        onPhase?(self, phase)
    }

    private func received(_ reported: PrinterStatus, canceled: Bool) {
        var new = reported
        new.fit(to: config.model)
        let old = status
        status = new
        lastHeard = Date()
        if let light = pendingLight, new.chamberLightOn == light { pendingLight = nil }
        if let level = pendingSpeed, new.speed == level { pendingSpeed = nil }
        onStatus?(self, old, new, canceled)
        hasBaseline = true
    }
}
