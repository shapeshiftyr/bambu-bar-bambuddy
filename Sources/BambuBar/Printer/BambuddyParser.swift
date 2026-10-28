import Foundation

/// Turns Bambuddy's printer status (`GET /api/v1/printers/{id}/status`, with WebSocket `printer_status` pushes
/// merged over it) into a `PrinterStatus`. Bambuddy has already decoded most of the printer's report; the AMS
/// trays and HMS codes keep the printer's own field names, so those go through `ReportParser`.
enum BambuddyParser {
    static func status(from p: [String: Any], model: PrinterModel?, hms: HMSCatalog = .shared) -> PrinterStatus {
        var s = PrinterStatus()
        s.updatedAt = Date()
        // "unknown" (never heard from, or presumed off) folds to idle.
        s.state = JobState(gcodeState: string(p["state"]) ?? "IDLE")
        // -1 when there is no stage.
        s.stageID = int(p["stg_cur"]).flatMap { $0 < 0 ? nil : $0 }
        s.taskID = int(p["current_archive_id"]).map { String($0) }
        s.jobName = ReportParser.cleanJobName(string(p["subtask_name"]) ?? "", file: string(p["gcode_file"]) ?? "")
        s.progress = max(0, min(100, int(p["progress"]) ?? 0))
        s.remainingMinutes = max(0, int(p["remaining_time"]) ?? 0)
        s.layer = int(p["layer_num"]) ?? 0
        s.totalLayers = int(p["total_layers"]) ?? 0

        // On two-nozzle models Bambuddy's `nozzle` is the left one and `nozzle_2` the right; Bambu Bar's `nozzle`
        // is the right one, as Bambu Studio numbers them.
        let t = p["temperatures"] as? [String: Any] ?? [:]
        func temperature(_ key: String) -> Temperature? {
            guard let current = double(t[key]) else { return nil }
            return Temperature(current: current, target: double(t[key + "_target"]) ?? 0)
        }
        if let right = temperature("nozzle_2"), (model?.nozzleCount ?? 1) >= 2 {
            s.nozzle = right
            s.secondNozzle = temperature("nozzle")
            s.leftNozzleInUse = int(p["active_extruder"]) == 1
        } else {
            s.nozzle = temperature("nozzle") ?? Temperature(current: 0, target: 0)
        }
        s.bed = temperature("bed") ?? Temperature(current: 0, target: 0)
        if let chamber = double(t["chamber"]), chamber > 0, chamber <= 120 {
            s.chamber = chamber
            s.chamberTarget = double(t["chamber_target"])
        }

        // Already in percent.
        s.partFan = percent(p["cooling_fan_speed"])
        s.auxFan = percent(p["big_fan1_speed"])
        s.exhaustFan = percent(p["big_fan2_speed"])
        s.heatbreakFan = percent(p["heatbreak_fan_speed"])

        s.speed = SpeedLevel(rawValue: int(p["speed_level"]) ?? 2) ?? .standard
        s.chamberLightOn = p["chamber_light"] as? Bool
        s.doorOpen = p["door_open"] as? Bool
        if let wifi = string(p["wifi_signal"]), let dbm = Int(wifi.replacingOccurrences(of: "dBm", with: "")) {
            s.wifiSignal = dbm
        }
        // Commands only go through with Developer Mode on; nil means Bambuddy can't tell yet.
        s.controlsLocked = p["developer_mode"] as? Bool == false
        s.firmware = string(p["firmware_version"]).flatMap { $0.isEmpty ? nil : $0 }
        if let nozzle = (p["nozzles"] as? [[String: Any]])?.first {
            s.nozzleDiameter = double(nozzle["nozzle_diameter"])
            s.nozzleType = string(nozzle["nozzle_type"]).flatMap { $0.isEmpty ? nil : $0 }
        }
        s.hasSDCard = p["sdcard"] as? Bool
        s.liveViewEnabled = p["ipcam"] as? Bool
        s.plateIndex = int(p["current_plate_id"])

        parseFilament(p, model: model, into: &s)
        s.issues = issues(p, hms: hms)
        s.canceled = s.state == .failed && wasCanceled(p)
        return s
    }

    /// The job ended because someone stopped it: Bambuddy lists the printer's cancel echo among `hms_errors`.
    static func wasCanceled(_ p: [String: Any]) -> Bool {
        errorCodes(p).contains { $0.count == 8 && UInt32($0, radix: 16).map(ReportParser.isCancel) == true }
    }

    // MARK: - Filament

    private static func parseFilament(_ p: [String: Any], model: PrinterModel?, into s: inout PrinterStatus) {
        let units = p["ams"] as? [[String: Any]] ?? []
        s.ams = units.compactMap { u -> AMSUnit? in
            guard let id = int(u["id"]) else { return nil }
            let module = string(u["module_type"])?.lowercased()
            let kind: AMSKind
            if id >= 128 || module == "n3s" || u["is_ams_ht"] as? Bool == true {
                kind = .ht
            } else if module == "n3f" {
                kind = .pro2
            } else {
                kind = model?.usesAMSLite == true ? .lite : .ams
            }
            let trays = u["tray"] as? [[String: Any]] ?? []
            let spools = trays.compactMap { t -> Spool? in
                guard let slot = int(t["id"]) else { return nil }
                return spool(t, id: id >= 128 ? id : id * 4 + slot, unit: id, slot: slot)
            }.sorted { $0.slot < $1.slot }
            // Bambuddy sends the relative humidity in percent, not the printer's 1-5 scale.
            var humidity = int(u["humidity"])
            if let h = humidity, h < 1 || h > 100 { humidity = nil }
            var temp = double(u["temp"])
            if let t = temp, t <= 0 || t > 100 { temp = nil }
            return AMSUnit(id: id, kind: kind, humidity: humidity, humidityLevel: nil, temperature: temp,
                           dryingMinutesLeft: int(u["dry_time"]) ?? 0, spools: spools)
        }.sorted { $0.id < $1.id }

        // 254 is the (left) external holder; the H2's right one (255) isn't shown separately.
        let virtual = p["vt_tray"] as? [[String: Any]] ?? []
        if let v = virtual.first(where: { int($0["id"]) == Spool.externalID }) ?? virtual.first {
            var ext = ReportParser.spoolFrom(v, id: Spool.externalID, unit: 255, slot: 0)
            ext.isLoaded = !(string(v["tray_type"]) ?? "").isEmpty
            // Nothing weighs the spool on the external holder; its `remain` is a placeholder.
            ext.remain = nil
            ReportParser.describe(&ext)
            s.externalSpool = ext
        }

        // Global slot number, as Bambu Bar numbers spools: unit * 4 + slot, the unit id for AMS HT, 254 external.
        switch int(p["tray_now"]) {
        case nil, 255: s.activeSpoolID = nil
        case 254: s.activeSpoolID = Spool.externalID
        case let now?: s.activeSpoolID = now
        }
        // Only meaningful while filament is actually in use.
        if !s.state.isActive && s.activeSpoolID != nil && s.activeSpool?.isLoaded != true { s.activeSpoolID = nil }
    }

    private static func spool(_ t: [String: Any], id: Int, unit: Int, slot: Int) -> Spool {
        var raw = t
        // Bambuddy's `state` (9 empty, 10 present, 11 loaded) isn't the printer's bit field; `exists` says it better.
        raw["state"] = nil
        var spool = ReportParser.spoolFrom(raw, id: id, unit: unit, slot: slot)
        if t["exists"] as? Bool == false { spool.isLoaded = false }
        ReportParser.describe(&spool)
        return spool
    }

    // MARK: - Issues

    /// `hms_errors[]`: a 16-digit `full_code` is an HMS message (attr + code), an 8-digit one the print error.
    private static func issues(_ p: [String: Any], hms catalog: HMSCatalog) -> [PrinterIssue] {
        var out: [PrinterIssue] = []
        for entry in p["hms_errors"] as? [[String: Any]] ?? [] {
            guard let code = fullCode(entry) else { continue }
            var found: PrinterIssue?
            if code.count == 16, let attr = UInt32(code.prefix(8), radix: 16), let c = UInt32(code.suffix(8), radix: 16) {
                found = ReportParser.hmsIssue(attr: attr, code: c, hms: catalog)
            } else if code.count == 8, let e = UInt32(code, radix: 16) {
                found = ReportParser.printErrorIssue(e, hms: catalog)
            }
            guard var issue = found, !out.contains(where: { $0.id == issue.id || $0.id.hasSuffix(issue.id) }) else { continue }
            // Bambuddy's own text for a code the bundled catalogue doesn't know.
            if catalog.hmsText(code) == nil && catalog.errorText(code) == nil,
               let description = string(entry["description"]), !description.isEmpty {
                issue.message = description
            }
            out.append(issue)
        }
        return out.sorted { $0.severity < $1.severity }
    }

    private static func errorCodes(_ p: [String: Any]) -> [String] {
        (p["hms_errors"] as? [[String: Any]] ?? []).compactMap(fullCode)
    }

    /// The code as hex digits without separators ("0300400C", "0700230000020001").
    private static func fullCode(_ entry: [String: Any]) -> String? {
        guard let raw = string(entry["full_code"]) else { return nil }
        let hex = raw.uppercased().filter(\.isHexDigit)
        return hex.count == 8 || hex.count == 16 ? hex : nil
    }

    // MARK: - Helpers

    private static func percent(_ value: Any?) -> Int? { int(value).map { max(0, min(100, $0)) } }
    private static func int(_ value: Any?) -> Int? { ReportParser.int(value) }
    private static func double(_ value: Any?) -> Double? { ReportParser.double(value) }
    private static func string(_ value: Any?) -> String? { ReportParser.string(value) }
}
