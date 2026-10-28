import AppKit

/// macOS (15 and later) asks before an app talks to devices on the local network. Without that permission a
/// Bambuddy server on the LAN can't be reached, so the app says so and points to the switch.
enum LocalNetwork {
    static let advice = String(localized: "macOS is keeping Bambu Bar off your local network. If it asked, click Allow; otherwise turn on Bambu Bar in System Settings → Privacy & Security → Local Network.")

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }
}
