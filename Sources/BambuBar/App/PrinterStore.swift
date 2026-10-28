import AppKit
import Observation
import WidgetKit

/// What the menu bar shows next to the icon.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, percent, remaining, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return String(localized: "Icon only", comment: "Menu bar style")
        case .percent: return String(localized: "Progress", comment: "Menu bar style")
        case .remaining: return String(localized: "Time left", comment: "Menu bar style")
        case .both: return String(localized: "Progress and time left", comment: "Menu bar style")
        }
    }
}

/// The app's single source of truth: the Bambuddy server, its printers, which one is in view, job history and
/// settings. The printer list follows the server; every printer the API key can see gets a session.
///
/// The window and the menu bar panel show the *selected* printer; the members below without a session
/// argument (`status`, `pause()`…) act on it. The menu bar icon shows `menuBarSession`, which follows
/// the Settings choice ("Automatic" picks whichever printer is busy).
@MainActor
@Observable
final class PrinterStore {
    static let shared = PrinterStore()

    private(set) var sessions: [PrinterSession] = []
    private(set) var selectedSerial: String?
    private(set) var history: [JobRecord] = []
    /// The Bambuddy server, nil until one is set up.
    private(set) var serverURL: URL?
    /// Whether the server answers and accepts the API key.
    private(set) var serverPhase: PrinterConnection.Phase = .idle
    /// A short-lived message after a command ("The printer refused…").
    private(set) var toast: Toast?
    private(set) var isDemo = false

    /// `nil` = automatic.
    var menuBarSerial: String? {
        didSet { defaults.set(menuBarSerial, forKey: Keys.menuBarPrinter); writeSnapshot(force: true) }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: Keys.notifyFinished); requestNotificationsIfNeeded() } }
    var notifyFailed: Bool { didSet { defaults.set(notifyFailed, forKey: Keys.notifyFailed); requestNotificationsIfNeeded() } }
    var notifyPaused: Bool { didSet { defaults.set(notifyPaused, forKey: Keys.notifyPaused); requestNotificationsIfNeeded() } }
    var notifyStarted: Bool { didSet { defaults.set(notifyStarted, forKey: Keys.notifyStarted); requestNotificationsIfNeeded() } }
    var confirmStop: Bool { didSet { defaults.set(confirmStop, forKey: Keys.confirmStop) } }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    private let defaults = UserDefaults.standard
    private var hub: BambuddyHub?
    private let notifier = Notifier()
    private var lastWidgetReload = Date.distantPast
    private var lastSnapshotWrite = Date.distantPast
    private var lastSavedKey = ""
    private var lastWidgetKey = ""
    private var isStarted = false
    private var toastTask: Task<Void, Never>?

    private enum Keys {
        static let server = "bambuddyServer"
        static let printers = "printers"
        static let selected = "selectedPrinter"
        static let menuBarPrinter = "menuBarPrinter"
        static let menuBarStyle = "menuBarStyle"
        static let notifyFinished = "notifyFinished"
        static let notifyFailed = "notifyFailed"
        static let notifyPaused = "notifyPaused"
        static let notifyStarted = "notifyStarted"
        static let confirmStop = "confirmStop"
    }

    private init() {
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .both
        notifyFinished = defaults.object(forKey: Keys.notifyFinished) as? Bool ?? true
        notifyFailed = defaults.object(forKey: Keys.notifyFailed) as? Bool ?? true
        notifyPaused = defaults.object(forKey: Keys.notifyPaused) as? Bool ?? true
        notifyStarted = defaults.object(forKey: Keys.notifyStarted) as? Bool ?? false
        confirmStop = defaults.object(forKey: Keys.confirmStop) as? Bool ?? true
        menuBarSerial = defaults.string(forKey: Keys.menuBarPrinter)
        selectedSerial = defaults.string(forKey: Keys.selected)
        serverURL = defaults.string(forKey: Keys.server).flatMap(URL.init(string:))
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        if let scenario = DemoDriver.requestedScenario {
            startDemo(scenario)
            return
        }

        // The printers from last time show (offline) until the server answers.
        for config in loadConfigs() { add(config) }
        history = HistoryStore.load()
        if selectedSerial == nil || session(selectedSerial!) == nil { selectedSerial = sessions.first?.id }
        if let serverURL, let key = Keychain.apiKey(for: serverURL.absoluteString) {
            startHub(BambuddyClient(baseURL: serverURL, apiKey: key))
        }
        writeSnapshot(force: true)
    }

    func stop() {
        for session in sessions { session.stop() }
        hub?.stop()
    }

    private func loadConfigs() -> [PrinterConfig] {
        guard let data = defaults.data(forKey: Keys.printers),
              let configs = try? JSONDecoder().decode([PrinterConfig].self, from: data) else { return [] }
        // Printers saved before Bambuddy have no id there; the server's list brings them back.
        return configs.filter { $0.bambuddyID != 0 }
    }

    private func saveConfigs() {
        guard !isDemo else { return }
        if let data = try? JSONEncoder().encode(sessions.map(\.config)) { defaults.set(data, forKey: Keys.printers) }
    }

    // MARK: - Bambuddy server

    var hasServer: Bool { serverURL != nil }

    /// "Connected", "API key rejected"… for the server as a whole.
    var serverSummary: String {
        switch serverPhase {
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .online: return String(localized: "Connected · \(sessions.count) printers")
        case .offline: return String(localized: "Offline")
        case .unauthorized: return String(localized: "API key rejected")
        case .certificate: return String(localized: "Certificate not trusted")
        case .localNetworkDenied: return String(localized: "No local network access")
        }
    }

    var serverDetail: String? {
        switch serverPhase {
        case .offline(let reason): return reason
        case .unauthorized: return BambuddyError.unauthorized.message
        case .certificate(let reason): return BambuddyError.certificate(reason).message
        case .localNetworkDenied: return LocalNetwork.advice
        default: return nil
        }
    }

    var serverAPIKey: String? { serverURL.flatMap { Keychain.apiKey(for: $0.absoluteString) } }

    /// Checks the server and the key, then saves them and shows the server's printers. Returns how many it has.
    @discardableResult
    func connectServer(url: URL, apiKey: String) async throws -> Int {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = BambuddyClient(baseURL: url, apiKey: key)
        // Needs no key, so a server that isn't there says so before a key that's wrong does.
        do {
            _ = try await client.version()
        } catch let error as BambuddyError {
            switch error {
            case .unreachable, .certificate, .localNetworkDenied: throw error
            default: break  // an older Bambuddy without the endpoint
            }
        }
        let printers = try await client.printers().filter(\.isActive)

        if let old = serverURL, old != url {
            Keychain.removeAPIKey(for: old.absoluteString)
            // Printer ids belong to the old server.
            for session in sessions { session.stop() }
            sessions = []
        }
        if !isDemo {
            defaults.set(url.absoluteString, forKey: Keys.server)
            Keychain.setAPIKey(key, for: url.absoluteString)
        }
        serverURL = url
        startHub(client)
        sync(printers)
        return printers.count
    }

    /// Forgets the server, its key and its printers. Print history stays.
    func disconnectServer() {
        hub?.stop()
        hub = nil
        serverPhase = .idle
        for session in sessions { session.stop() }
        sessions = []
        if let serverURL { Keychain.removeAPIKey(for: serverURL.absoluteString) }
        serverURL = nil
        selectedSerial = nil
        menuBarSerial = nil
        defaults.removeObject(forKey: Keys.server)
        defaults.removeObject(forKey: Keys.printers)
        writeSnapshot(force: true)
    }

    private func startHub(_ client: BambuddyClient) {
        hub?.stop()
        let hub = BambuddyHub(client: client)
        hub.onPhase = { [weak self] phase in self?.serverPhase = phase }
        hub.onPrinters = { [weak self] printers in self?.sync(printers) }
        self.hub = hub
        for session in sessions { session.start(hub: hub) }
        hub.start()
    }

    /// Makes the sessions match the server's printer list: new printers added, removed ones dropped, names,
    /// models and addresses brought up to date. A name changed in Bambu Bar stays.
    private func sync(_ printers: [BambuddyPrinter]) {
        guard let hub else { return }
        for printer in printers {
            if let session = session(printer.serial) {
                var config = session.config
                let renamed = config.bambuddyName.map { config.name != $0 } ?? false
                config.host = printer.host
                config.modelCode = Self.modelCode(printer)
                config.bambuddyID = printer.id
                config.bambuddyName = printer.name
                if !renamed { config.name = printer.name }
                guard config != session.config else { continue }
                // The connection keeps the id it follows and the model it reads the status for.
                let restart = config.bambuddyID != session.config.bambuddyID || config.modelCode != session.config.modelCode
                session.config = config
                if restart { session.start(hub: hub) }
            } else {
                add(PrinterConfig(host: printer.host, serial: printer.serial, name: printer.name,
                                  modelCode: Self.modelCode(printer), bambuddyID: printer.id, bambuddyName: printer.name))
                    .start(hub: hub)
            }
        }
        let serials = Set(printers.map(\.serial))
        for session in sessions where !serials.contains(session.id) { session.stop() }
        // Bambuddy's order, so the picker matches its printer page.
        sessions = printers.compactMap { p in sessions.first { $0.id == p.serial } }
        if selectedSerial == nil || session(selectedSerial!) == nil { selectedSerial = sessions.first?.id }
        if let menuBarSerial, session(menuBarSerial) == nil { self.menuBarSerial = nil }
        saveConfigs()
        writeSnapshot(force: true)
    }

    /// Bambuddy's model ("X1C", "A1 Mini") as one of Bambu Bar's model ids, falling back to the serial's prefix.
    private static func modelCode(_ printer: BambuddyPrinter) -> String {
        PrinterModel.named(printer.model)?.code ?? PrinterModel.find(code: "", serial: printer.serial)?.code ?? printer.model
    }

    // MARK: - Printers

    @discardableResult
    private func add(_ config: PrinterConfig) -> PrinterSession {
        let session = PrinterSession(config: config)
        session.onPhase = { [weak self] session, phase in
            // Reconnect attempts flip between offline and connecting; only settled states earn a widget reload.
            self?.writeSnapshot(force: phase == .online || phase == .unauthorized || phase == .idle)
        }
        session.onStatus = { [weak self] session, old, new, canceled in
            self?.trackJob(session, from: old, to: new, canceled: canceled)
            self?.writeSnapshot(force: old?.state != new.state)
        }
        session.onAck = { [weak self] session, command, ok, reason in self?.acknowledged(session, ok: ok, reason: reason) }
        session.onHeartbeat = { [weak self] _ in
            // A quiet, unchanging printer is still alive; keep the widget's snapshot from looking stale.
            guard let self, Date().timeIntervalSince(self.lastSnapshotWrite) > 300 else { return }
            self.writeSnapshot(force: false)
        }
        sessions.append(session)
        return session
    }

    func session(_ serial: String) -> PrinterSession? { sessions.first { $0.id == serial } }

    /// The printer the window and panel show.
    var current: PrinterSession? { selectedSerial.flatMap(session) ?? sessions.first }

    func select(_ serial: String) {
        guard session(serial) != nil, selectedSerial != serial else { return }
        selectedSerial = serial
        if !isDemo { defaults.set(serial, forKey: Keys.selected) }
    }

    /// The printer the menu bar icon follows: the one chosen in Settings, or automatically the busiest.
    var menuBarSession: PrinterSession? {
        if let menuBarSerial, let chosen = session(menuBarSerial) { return chosen }
        func rank(_ s: PrinterSession) -> Int {
            guard let status = s.status, s.isOnline else { return 0 }
            if status.mostSevereIssue.map({ $0.severity <= .serious }) == true && status.state.isActive { return 4 }
            switch status.state {
            case .paused: return 4
            case .printing, .preparing: return 3
            case .failed, .finished: return 1
            case .idle: return 0
            }
        }
        let best = sessions.max { rank($0) < rank($1) }
        if let best, rank(best) >= 3 { return best }
        return current
    }

    var hasMultiplePrinters: Bool { sessions.count > 1 }

    /// The name Bambuddy has for the printer, when Bambu Bar shows another one.
    func bambuddyName(for serial: String) -> String? {
        guard let config = session(serial)?.config, let name = config.bambuddyName, !name.isEmpty, name != config.name else { return nil }
        return name
    }

    /// Renames the printer in Bambu Bar only; Bambuddy keeps its name.
    func rename(_ serial: String, to name: String) {
        guard let session = session(serial) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.config.name = trimmed.isEmpty ? session.config.bambuddyName ?? serial : trimmed
        saveConfigs()
        writeSnapshot(force: true)
    }

    func refresh() {
        hub?.syncNow()
        current?.refresh()
    }

    /// macOS keeps the app off the local network, where the server is.
    var localNetworkBlocked: Bool { serverPhase == .localNetworkDenied }

    // MARK: - The current printer

    var isConfigured: Bool { !sessions.isEmpty }
    var config: PrinterConfig? { current?.config }
    var phase: PrinterConnection.Phase { current?.phase ?? .idle }
    var status: PrinterStatus? { current?.status }
    var isOnline: Bool { current?.isOnline ?? false }
    var printerName: String { current?.config.name ?? String(localized: "Printer") }
    var chamberLightOn: Bool { current?.chamberLightOn ?? false }
    var speed: SpeedLevel { current?.speed ?? .standard }
    var linkSummary: String { current?.linkSummary ?? String(localized: "No printer set up") }
    var linkDetail: String? { current?.linkDetail }

    /// The current printer's most recent print (for "Last: …" and "finished 3h ago").
    var lastJob: JobRecord? { history(for: current?.id).first }

    func history(for serial: String?) -> [JobRecord] {
        guard let serial else { return [] }
        return history.filter { $0.printerSerial == serial }
    }

    // MARK: - Commands (current printer)

    func pause() {
        guard let current, ensureControllable(current) else { return }
        current.pause()
        showToast("Pausing…")
    }

    func resume() {
        guard let current, ensureControllable(current) else { return }
        current.resume()
        showToast("Resuming…")
    }

    func stopPrint() {
        guard let current, ensureControllable(current) else { return }
        if confirmStop {
            let job = current.status?.jobName ?? ""
            let alert = NSAlert()
            alert.messageText = job.isEmpty ? String(localized: "Stop this print?") : String(localized: "Stop “\(job)”?")
            let warning = String(localized: "The print can't be resumed after it's stopped.")
            alert.informativeText = hasMultiplePrinters ? String(localized: "On \(current.config.name).", comment: "Which printer") + " " + warning : warning
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Stop Print"))
            alert.addButton(withTitle: String(localized: "Keep Printing"))
            alert.buttons.first?.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        current.stopPrint()
        showToast(String(localized: "Stopping…"))
    }

    func toggleLight() { current?.toggleLight() }

    func setSpeed(_ level: SpeedLevel) {
        guard let current, ensureControllable(current) else { return }
        current.setSpeed(level)
    }

    /// Print commands need the printer in Developer Mode; say so instead of sending something it will refuse.
    private func ensureControllable(_ session: PrinterSession) -> Bool {
        if session.status?.controlsLocked == true {
            showToast(String(localized: "Turn on LAN Only and Developer Mode on the printer to control prints from Bambu Bar."), error: true)
            return false
        }
        return true
    }

    private func acknowledged(_ session: PrinterSession, ok: Bool, reason: String?) {
        guard !ok else { return }
        let detail = reason ?? String(localized: "Bambuddy couldn't send the command to the printer.")
        showToast(hasMultiplePrinters ? "\(session.config.name): \(detail)" : detail, error: true)
    }

    func showToast(_ message: String, error: Bool = false) {
        toast = Toast(message: message, isError: error)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(error ? 6 : 3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Recent prints and notifications

    private func trackJob(_ session: PrinterSession, from old: PrinterStatus?, to new: PrinterStatus, canceled: Bool) {
        let serial = session.id
        // Simulated printers never post real notifications.
        let notify = session.hasBaseline && !isDemo
        let name = new.jobName.isEmpty ? String(localized: "Untitled print") : new.jobName
        let spool = new.activeSpool
        // Notification titles name the printer once there's more than one.
        let prefix = hasMultiplePrinters ? "\(session.config.name): " : ""
        let running = history.firstIndex { $0.printerSerial == serial && $0.outcome == .running }

        // Start of a job, or the first report of one already running.
        if new.state.isActive && (old == nil || !(old!.state.isActive)) {
            let current = running.map { history[$0] }
            let sameJob = current?.name == name
                && (current?.taskID == nil || new.taskID == nil || current?.taskID == new.taskID)
            if !sameJob {
                // Anything still marked running on this printer ended while the app wasn't looking.
                for i in history.indices where history[i].printerSerial == serial && history[i].outcome == .running {
                    history[i].outcome = .ended
                }
                let elapsed = estimateElapsed(new)
                history.insert(JobRecord(name: name, startedAt: Date().addingTimeInterval(-elapsed), endedAt: nil,
                                         outcome: .running, totalLayers: new.totalLayers,
                                         filamentColor: spool?.color, filamentMaterial: spool?.material,
                                         taskID: new.taskID, printerSerial: serial), at: 0)
                HistoryStore.save(history)
            }
            if notify, old != nil, notifyStarted {
                notifier.post(title: prefix + String(localized: "Print started"), body: name, id: "start.\(serial)")
            }
        }
        if let index = history.firstIndex(where: { $0.printerSerial == serial && $0.outcome == .running }) {
            var job = history[index]
            // Keep details fresh while it runs (the name arrives late on printer-started jobs).
            job.name = name
            if new.totalLayers > 0 { job.totalLayers = new.totalLayers }
            if let spool { job.filamentColor = spool.color; job.filamentMaterial = spool.material }
            if !new.state.isActive {
                job.endedAt = Date()
                switch new.state {
                case .finished: job.outcome = .finished
                case .failed: job.outcome = canceled ? .canceled : .failed
                // Straight back to idle without FINISH: stopped from the printer, or the report was missed.
                default: job.outcome = canceled ? .canceled : .ended
                }
                if notify { notifyEnd(job, status: new, prefix: prefix, serial: serial) }
            }
            if job != history[index] {
                history[index] = job
                HistoryStore.save(history)
            }
        }
        if notify, let old, old.state == .printing || old.state == .preparing, new.state == .paused, notifyPaused {
            notifier.post(title: prefix + String(localized: "Print paused"), body: "\(name): \(new.detailText)", id: "pause.\(serial)")
        }
        if notify, let old {
            let fresh = new.issues.filter { issue in issue.severity <= .serious && !old.issues.contains { $0.id == issue.id } }
            if let issue = fresh.first, notifyFailed || notifyPaused {
                notifier.post(title: "\(session.config.name): \(issue.severity.title)", body: issue.message, id: "\(issue.id).\(serial)")
            }
        }
    }

    private func notifyEnd(_ job: JobRecord, status: PrinterStatus, prefix: String, serial: String) {
        switch job.outcome {
        case .finished where notifyFinished:
            let body = job.duration.map {
                String(localized: "\(job.name) finished in \(Format.duration(seconds: $0)). It's ready to take off the plate.", comment: "Job name, then how long it took")
            } ?? String(localized: "\(job.name) finished. It's ready to take off the plate.")
            notifier.post(title: prefix + String(localized: "Print finished"), body: body, id: "end.\(serial)")
        case .failed where notifyFailed:
            let reason = status.issues.first?.message ?? String(localized: "the printer stopped the job.", comment: "After the job name and a colon")
            notifier.post(title: prefix + String(localized: "Print failed"), body: "\(job.name): \(reason)", id: "end.\(serial)")
        case .canceled where notifyFailed:
            notifier.post(title: prefix + String(localized: "Print canceled"), body: job.name, id: "end.\(serial)")
        default:
            break
        }
    }

    private func estimateElapsed(_ s: PrinterStatus) -> TimeInterval {
        guard s.progress > 0, s.progress < 100, s.remainingMinutes > 0 else { return 0 }
        return Double(s.remainingMinutes * 60) * Double(s.progress) / Double(100 - s.progress)
    }

    private func requestNotificationsIfNeeded() {
        if notifyFinished || notifyFailed || notifyPaused || notifyStarted { notifier.requestAuthorization() }
    }

    // MARK: - Widget

    func snapshot(of session: PrinterSession) -> SharedSnapshot {
        let link: SharedSnapshot.Link
        switch session.phase {
        case .online: link = .online
        case .connecting: link = session.status == nil ? .connecting : .online
        case .unauthorized: link = .unauthorized
        case .idle, .offline, .certificate, .localNetworkDenied: link = .offline
        }
        return SharedSnapshot(serial: session.id, printerName: session.config.name, model: session.config.modelName,
                              link: link, status: session.status,
                              lastJob: history.first { $0.printerSerial == session.id && $0.outcome != .running },
                              savedAt: Date())
    }

    /// The current printer as the widget would show it (for the gallery in Settings).
    var snapshot: SharedSnapshot { current.map(snapshot(of:)) ?? .unconfigured() }

    var fleet: SharedFleet {
        SharedFleet(printers: sessions.map(snapshot(of:)), menuBarSerial: menuBarSession?.id, savedAt: Date())
    }

    /// Writes the widgets' snapshot and asks WidgetKit to reload when something a person would notice changed.
    /// Widget timelines extrapolate progress on their own, so routine progress needs only occasional reloads.
    private func writeSnapshot(force: Bool) {
        // Demo and developer sessions must never show up in the real widgets.
        guard !isDemo else { return }
        let fleet = fleet
        let key = fleet.printers.map { snap -> String in
            let s = snap.status
            return "\(snap.serial)|\(snap.link)|\(snap.printerName)|\(s?.state.rawValue ?? "-")|\(s?.stageID ?? -9)|\((s?.progress ?? 0) / 5)|\(s?.jobName ?? "")|\(s?.issues.count ?? 0)|\(s?.activeSpoolID ?? -1)|\(s?.ams.flatMap(\.spools).map(\.color).joined() ?? "")"
        }.joined(separator: "#") + "|\(fleet.menuBarSerial ?? "")"
        // Reports arrive every second; the file only needs to be fresh when the widget next reads it.
        if force || key != lastSavedKey || Date().timeIntervalSince(lastSnapshotWrite) > 20 {
            SharedStore.save(fleet)
            lastSnapshotWrite = Date()
            lastSavedKey = key
        }
        let elapsed = Date().timeIntervalSince(lastWidgetReload)
        guard key != lastWidgetKey, force || elapsed > 120 else { return }
        lastWidgetKey = key
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Demo

    private func startDemo(_ scenario: DemoDriver.Scenario) {
        isDemo = true
        guard scenario != .unconfigured else {
            writeSnapshot(force: true)
            return
        }
        // Not saved: a demo run must not replace the real printers' settings.
        var printers = [(PrinterConfig(host: "192.168.1.50", serial: "22E00A000000000", name: "P2S Workshop", modelCode: "N7"), scenario)]
        if CommandLine.arguments.contains("--fleet") {
            printers.append((PrinterConfig(host: "192.168.1.51", serial: "00M00A000000000", name: "X1C Garage", modelCode: "BL-P001"), .idle))
            printers.append((PrinterConfig(host: "192.168.1.52", serial: "039000000000000", name: "A1 Desk", modelCode: "N2S"), .paused))
            printers.append((PrinterConfig(host: "192.168.1.53", serial: "094000000000000", name: "H2D Studio", modelCode: "O1D"), .printing))
            printers.append((PrinterConfig(host: "192.168.1.54", serial: "030000000000000", name: "A1 mini Shelf", modelCode: "N1"), .finished))
            printers.append((PrinterConfig(host: "192.168.1.55", serial: "01P000000000000", name: "P1S Office", modelCode: "C12"), .printing))
        }
        for (index, (config, scenario)) in printers.enumerated() {
            add(config).startDemo(scenario, variant: index)
        }
        selectedSerial = sessions.first?.id
        history = DemoDriver.sampleHistory(for: sessions.map(\.id))
        writeSnapshot(force: true)
    }
}

/// The last few prints of every printer, newest first, in Application Support. Only what the app saw while
/// running; it backs "Last: …", finish times and end-of-print notifications, not a print log.
enum HistoryStore {
    /// Demo and developer sessions never touch the real history.
    private static var isEphemeral: Bool {
        CommandLine.arguments.contains("--demo")
    }

    private static var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bambu Bar", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [JobRecord] {
        guard !isEphemeral, let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([JobRecord].self, from: data)) ?? []
    }

    static func save(_ jobs: [JobRecord]) {
        guard !isEphemeral, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // A handful per printer is all the UI uses.
        var kept: [JobRecord] = []
        var perPrinter: [String: Int] = [:]
        for job in jobs {
            let key = job.printerSerial ?? ""
            guard perPrinter[key, default: 0] < 5 else { continue }
            perPrinter[key, default: 0] += 1
            kept.append(job)
        }
        try? encoder.encode(kept).write(to: url, options: .atomic)
    }
}
