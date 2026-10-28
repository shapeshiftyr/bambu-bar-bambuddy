import AppKit
import Foundation

/// One Bambuddy server: keeps its printer list in sync and holds the one WebSocket that pushes every printer's
/// status, handing each `printer_status` to the connection registered for that printer. Reconnects with back-off
/// when the server goes away or the Mac sleeps.
@MainActor
final class BambuddyHub {
    let client: BambuddyClient

    /// The server as a whole: reachable, key accepted.
    private(set) var phase: PrinterConnection.Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            for listener in listeners.values { listener.phase(phase) }
            onPhase?(phase)
        }
    }
    /// True while the WebSocket delivers pushes, so connections can poll less often.
    private(set) var isLive = false
    private(set) var printers: [BambuddyPrinter] = []

    var onPhase: ((PrinterConnection.Phase) -> Void)?
    var onPrinters: (([BambuddyPrinter]) -> Void)?

    private struct Listener {
        var data: ([String: Any]) -> Void
        var phase: (PrinterConnection.Phase) -> Void
    }

    private var listeners: [Int: Listener] = [:]
    private var syncTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var attempt = 0
    private var observers: [NSObjectProtocol] = []
    private let session = URLSession(configuration: .ephemeral)

    init(client: BambuddyClient) {
        self.client = client
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
    }

    func start() {
        guard syncTask == nil else { return }
        if phase == .idle { phase = .connecting }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.sync()
                // The printer list changes rarely; a failing server is retried sooner.
                try? await Task.sleep(for: .seconds(ok ? 60 : self.backoff()))
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        closeSocket()
        phase = .idle
    }

    /// Fetches the printer list now (Refresh, or after the person changed something in Bambuddy).
    func syncNow() {
        Task { await sync() }
    }

    func register(_ printerID: Int, data: @escaping ([String: Any]) -> Void, phase: @escaping (PrinterConnection.Phase) -> Void) {
        listeners[printerID] = Listener(data: data, phase: phase)
        phase(self.phase)
        // Ask for this printer's status over the socket too, in case it came up before the listener.
        send(["type": "get_status", "printer_id": printerID])
    }

    func unregister(_ printerID: Int) {
        listeners[printerID] = nil
    }

    /// A request from a connection failed in a way that says something about the whole server.
    func report(_ error: BambuddyError) {
        switch error {
        case .unauthorized: phase = .unauthorized
        case .certificate(let reason): phase = .certificate(reason)
        case .localNetworkDenied: phase = .localNetworkDenied
        case .unreachable(let reason): phase = .offline(reason)
        case .forbidden, .notConnected, .server: break
        }
    }

    // MARK: - Printer list

    @discardableResult
    private func sync() async -> Bool {
        do {
            let list = try await client.printers().filter(\.isActive)
            guard syncTask != nil else { return false }  // stopped meanwhile
            attempt = 0
            if phase != .online { phase = .online }
            if list != printers {
                printers = list
                onPrinters?(list)
            }
            if socket == nil && socketTask == nil { openSocket() }
            return true
        } catch let error as BambuddyError {
            guard syncTask != nil else { return false }
            if case .forbidden = error {
                phase = .offline(String(localized: "This API key can't read printers. Turn on Read status for it in Bambuddy → Settings → API Keys."))
            } else if case .server(let detail) = error {
                phase = .offline(detail)
            } else {
                report(error)
            }
            attempt += 1
            return false
        } catch {
            phase = .offline(error.localizedDescription)
            attempt += 1
            return false
        }
    }

    private func backoff() -> TimeInterval {
        let delays: [TimeInterval] = [2, 4, 8, 15, 30]
        return delays[min(max(attempt - 1, 0), delays.count - 1)]
    }

    // MARK: - WebSocket

    private func openSocket() {
        socketTask?.cancel()
        socketTask = Task { [weak self] in
            guard let self else { return }
            // The socket takes a short-lived token, not the API key. Without auth on the server there's no token
            // to get, and none is needed.
            let token: String?
            do {
                token = try await self.client.webSocketToken()
            } catch {
                token = nil
            }
            guard !Task.isCancelled else { return }
            guard let url = self.client.webSocketURL(token: token) else {
                self.socketTask = nil
                return
            }
            let socket = self.session.webSocketTask(with: url)
            self.socket = socket
            socket.resume()
            let pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self?.send(["type": "ping"])
                }
            }
            defer { pinger.cancel() }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    self.received(message)
                }
            } catch {
                // Closed: the server restarted, the token was refused (4401) or the network went away.
            }
            guard self.socket === socket else { return }
            let wasLive = self.isLive
            self.socket = nil
            self.socketTask = nil
            self.isLive = false
            // The sync loop reopens it on its next round. A socket that worked comes back sooner if the server is
            // still there; one refused outright (a key without WebSocket access) waits, and polling carries on.
            guard !Task.isCancelled, wasLive else { return }
            try? await Task.sleep(for: .seconds(self.backoff() + 3))
            if !Task.isCancelled, self.syncTask != nil, self.socket == nil, self.socketTask == nil, self.phase == .online {
                self.openSocket()
            }
        }
    }

    private func closeSocket() {
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isLive = false
    }

    private func received(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        isLive = true
        attempt = 0
        guard ReportParser.string(json["type"]) == "printer_status",
              let id = ReportParser.int(json["printer_id"]), let status = json["data"] as? [String: Any] else { return }
        listeners[id]?.data(status)
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: - Sleep

    private func suspend() {
        syncTask?.cancel()
        syncTask = nil
        closeSocket()
    }

    private func resume() {
        guard phase != .idle else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }
}
