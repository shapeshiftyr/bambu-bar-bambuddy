import Foundation

/// Why a request to the Bambuddy server didn't work.
enum BambuddyError: Error, Equatable {
    /// The API key is wrong, disabled or expired (401).
    case unauthorized
    /// The key works but lacks the permission for this request (403).
    case forbidden(String?)
    /// Bambuddy has no live connection to the printer (400 "Printer not connected").
    case notConnected
    /// No answer from the server.
    case unreachable(String)
    /// The server's TLS certificate didn't check out.
    case certificate(String)
    /// macOS keeps the app off the local network.
    case localNetworkDenied
    /// Any other error, with Bambuddy's `detail` when it sent one.
    case server(String)

    var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "Bambuddy rejected the API key. Check it under Settings → API Keys in Bambuddy.")
        case .forbidden(let detail):
            return detail ?? String(localized: "This API key isn't allowed to do that.")
        case .notConnected: return String(localized: "Bambuddy isn't connected to this printer.")
        case .unreachable(let reason): return reason
        case .certificate(let reason): return String(localized: "The server's TLS certificate couldn't be verified: \(reason)")
        case .localNetworkDenied: return LocalNetwork.advice
        case .server(let detail): return detail
        }
    }
}

/// One printer as Bambuddy lists it (`GET /api/v1/printers/`).
struct BambuddyPrinter: Equatable, Sendable {
    var id: Int
    var name: String
    var serial: String
    var host: String
    /// "X1C", "P1S", "A1 Mini"… or a model id ("N7").
    var model: String
    var isActive: Bool
}

/// The Bambuddy REST API, authenticated with an API key (`X-API-Key`). Responses come back as untyped JSON so
/// the status parser can read the printer's raw field names the way `ReportParser` does.
struct BambuddyClient: Sendable {
    let baseURL: URL
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Turns what the person typed ("192.168.1.10:8000", "https://bambuddy.example.com/") into a base URL.
    static func normalize(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        // A pasted web UI or API link: keep only the server.
        if let range = text.range(of: "/api/") { text = String(text[..<range.lowerBound]) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    // MARK: - Endpoints

    /// Bambuddy's version; needs no key, so it tells "server not there" apart from "key wrong".
    func version() async throws -> String {
        let json = try await object("GET", "updates/version", authenticated: false)
        return ReportParser.string(json["version"]) ?? "?"
    }

    func printers() async throws -> [BambuddyPrinter] {
        // The trailing slash matters: FastAPI redirects without it.
        let list = try await array("GET", "printers/")
        return list.compactMap { p in
            guard let id = ReportParser.int(p["id"]), let serial = ReportParser.string(p["serial_number"]) else { return nil }
            return BambuddyPrinter(id: id, name: ReportParser.string(p["name"]) ?? serial, serial: serial.uppercased(),
                                   host: ReportParser.string(p["ip_address"]) ?? "", model: ReportParser.string(p["model"]) ?? "",
                                   isActive: p["is_active"] as? Bool ?? true)
        }
    }

    func status(_ id: Int) async throws -> [String: Any] {
        try await object("GET", "printers/\(id)/status")
    }

    /// Asks the printer for a full report (a `pushall`).
    func refresh(_ id: Int) async throws {
        _ = try await object("POST", "printers/\(id)/refresh-status")
    }

    /// A control command: `print/pause`, `chamber-light` with `on=true`…
    func command(_ id: Int, _ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await object("POST", "printers/\(id)/\(path)", query: query)
    }

    /// A token for the WebSocket, which doesn't take the API key itself. Valid for an hour.
    func webSocketToken() async throws -> String {
        let json = try await object("POST", "auth/ws-token")
        guard let token = ReportParser.string(json["token"]) else { throw BambuddyError.server("No WebSocket token in the response.") }
        return token
    }

    /// `ws(s)://server/api/v1/ws?token=…`
    func webSocketURL(token: String?) -> URL? {
        guard var components = URLComponents(url: endpoint("ws"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        if let token { components.queryItems = [URLQueryItem(name: "token", value: token)] }
        return components.url
    }

    // MARK: - Transport

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent("api/v1/" + path, isDirectory: path.hasSuffix("/"))
    }

    private func object(_ method: String, _ path: String, query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> [String: Any] {
        let json = try await send(method, path, query: query, authenticated: authenticated)
        return json as? [String: Any] ?? [:]
    }

    private func array(_ method: String, _ path: String) async throws -> [[String: Any]] {
        let json = try await send(method, path, query: [], authenticated: true)
        guard let list = json as? [[String: Any]] else { throw BambuddyError.server(String(localized: "Unexpected answer from Bambuddy.")) }
        return list
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem], authenticated: Bool) async throws -> Any? {
        var url = endpoint(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        guard let http = response as? HTTPURLResponse else { return json }
        guard !(200..<300).contains(http.statusCode) else { return json }

        let detail = Self.detail(json)
        switch http.statusCode {
        case 401: throw BambuddyError.unauthorized
        case 403: throw BambuddyError.forbidden(detail)
        case 400 where detail?.localizedCaseInsensitiveContains("not connected") == true: throw BambuddyError.notConnected
        case 404 where json == nil || detail == "Not Found":
            throw BambuddyError.server(String(localized: "No Bambuddy API at \(baseURL.absoluteString)."))
        default:
            throw BambuddyError.server(detail ?? String(localized: "Bambuddy answered with error \(http.statusCode)."))
        }
    }

    /// FastAPI's `{"detail": "…"}`, or the first message of a validation error list.
    private static func detail(_ json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return nil }
        if let text = object["detail"] as? String { return text }
        if let list = object["detail"] as? [[String: Any]] { return list.first?["msg"] as? String }
        return nil
    }

    static func transportError(_ error: Error) -> BambuddyError {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return .unreachable(error.localizedDescription) }
        switch error.code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return .certificate(error.localizedDescription)
        case NSURLErrorTimedOut:
            return .unreachable(String(localized: "The Bambuddy server didn't answer in time."))
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .unreachable(String(localized: "Can't reach the Bambuddy server. Check that it's running and the address is right."))
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            // A LAN server that macOS keeps the app away from looks like no network at all.
            if String(describing: error).localizedCaseInsensitiveContains("local network prohibited") {
                return .localNetworkDenied
            }
            return .unreachable(String(localized: "This Mac is offline."))
        default:
            return .unreachable(error.localizedDescription)
        }
    }
}
