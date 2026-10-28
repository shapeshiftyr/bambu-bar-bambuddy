import Foundation

/// What the printer's own field names mean, shared by `BambuddyParser`: Bambuddy passes the AMS trays and HMS
/// codes through as the printer reports them.
enum ReportParser {
    // MARK: - Filament

    static func spoolFrom(_ t: [String: Any], id: Int, unit: Int, slot: Int) -> Spool {
        let material = string(t["tray_type"]) ?? ""
        let state = int(t["state"])
        var loaded = !material.isEmpty
        if let state, state > 3 { loaded = state & 0x01 != 0 && state & 0x08 != 0 || state == 9 }
        let color = string(t["tray_color"]) ?? "00000000"
        let colors = (t["cols"] as? [String])?.filter { $0.count >= 6 } ?? []
        var remain = int(t["remain"])
        if let r = remain, r < 0 || r > 100 { remain = nil }
        let tag = string(t["tag_uid"]) ?? ""
        var weight = int(t["tray_weight"])
        if let w = weight, w <= 0 || w > 10_000 { weight = nil }
        var spool = Spool(id: id, unit: unit, slot: slot, material: material, name: string(t["tray_sub_brands"]) ?? "",
                          color: color, colors: colors.isEmpty ? [color] : colors, remain: remain, weight: weight, isLoaded: loaded,
                          isBambu: !tag.isEmpty && !tag.allSatisfy { $0 == "0" },
                          preset: string(t["tray_info_idx"]).flatMap { $0.isEmpty ? nil : $0 })
        spool.colorName = FilamentCatalog.colorName(tagCode: string(t["tray_id_name"]) ?? "", preset: spool.preset, hex: color)
        if let low = int(t["nozzle_temp_min"]), let high = int(t["nozzle_temp_max"]), low > 0, high >= low {
            spool.nozzleRange = low...high
        }
        return spool
    }

    /// Fills in the maker and product from the slot's preset once it's known whether the spool has a Bambu tag.
    /// A spool without one is whatever the slot was set to on the printer or in Bambu Studio.
    static func describe(_ spool: inout Spool) {
        guard spool.isLoaded else {
            spool = Spool(id: spool.id, unit: spool.unit, slot: spool.slot, material: "", name: "", color: spool.color,
                          colors: spool.colors, remain: nil, isLoaded: false, isBambu: false)
            return
        }
        let preset = spool.preset.flatMap(FilamentCatalog.preset)
        spool.brand = spool.isBambu ? "Bambu Lab" : preset?.vendor
        if spool.name.isEmpty, let product = preset?.product, product.caseInsensitiveCompare(spool.material) != .orderedSame {
            spool.name = product
        }
    }

    // MARK: - Issues

    /// One HMS message from its `attr` and `code`; nil for codes the printer reports but Bambu Studio hides.
    static func hmsIssue(attr a: UInt32, code c: UInt32, hms catalog: HMSCatalog) -> PrinterIssue? {
        if c & 0xFFFF < 0x4000 && c >> 16 == 0 { return nil }
        let key = String(format: "%08X%08X", a, c)
        let pretty = String(format: "HMS_%04X_%04X_%04X_%04X", a >> 16, a & 0xFFFF, c >> 16, c & 0xFFFF)
        let severity = IssueSeverity(rawValue: Int(c >> 16)) ?? .common
        return PrinterIssue(id: pretty, severity: severity,
                            message: catalog.hmsText(key) ?? String(localized: "The printer reported \(pretty).", comment: "An HMS code"),
                            wikiURL: HMSCatalog.wikiURL(for: pretty))
    }

    /// The current `print_error`; nil for none, and for the printer's echo of a user cancel.
    static func printErrorIssue(_ e: UInt32, hms catalog: HMSCatalog) -> PrinterIssue? {
        guard e != 0, !isCancel(e) else { return nil }
        let key = String(format: "%08X", e)
        let pretty = String(format: "%04X_%04X", e >> 16, e & 0xFFFF)
        let level = (e & 0xF000) >> 12
        let severity: IssueSeverity = level == 0x4 ? .fatal : level == 0x8 ? .serious : .common
        return PrinterIssue(id: pretty, severity: severity,
                            message: catalog.errorText(key) ?? String(localized: "The printer reported error \(pretty).", comment: "An error code"),
                            wikiURL: HMSCatalog.wikiURL(for: pretty))
    }

    /// 0300_400C and 0500_400E are the printer's echo of a user cancel, not a fault.
    static func isCancel(_ e: UInt32) -> Bool {
        let key = String(format: "%08X", e)
        return key == "0300400C" || key == "0500400E"
    }

    // MARK: - Helpers

    /// Bambu Studio names jobs after the 3MF; strip path and extensions for display.
    static func cleanJobName(_ name: String, file: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty {
            n = (file as NSString).lastPathComponent
            if n.hasPrefix("plate_") { n = "" }
        }
        for ext in [".gcode.3mf", ".3mf", ".gcode"] where n.lowercased().hasSuffix(ext) {
            n = String(n.dropLast(ext.count))
        }
        // Bambu Studio turns spaces into underscores when it names the job after the project file.
        if !n.contains(" ") { n = n.replacingOccurrences(of: "_", with: " ") }
        return n
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v) ?? Double(v).map { Int($0) }
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v.stringValue
        default: return nil
        }
    }
}
