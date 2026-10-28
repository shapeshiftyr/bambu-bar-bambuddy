import AppKit

/// One Bambu Bar at a time: a second copy (another build, or a launch racing the login item) hands over to the
/// one already running and quits, so there's one menu bar icon and one connection per printer. Demo and showcase
/// runs are left alone, since they're meant to run next to the installed app.
@MainActor
enum SingleInstance {
    private static let showWindow = Notification.Name("dev.rolottr.BambuBar.showWindow")

    /// The copy that was running first, other than this one.
    private static var other: NSRunningApplication? {
        let current = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != current && !$0.isTerminated }
            .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    /// Quits this copy if another one is running, after asking that one to show its window unless this launch was
    /// meant to stay in the background.
    static func handOverIfRunning(background: Bool) {
        guard !LaunchContext.isDeveloperRun, let other else { return }
        if !background {
            DistributedNotificationCenter.default().postNotificationName(showWindow, object: nil, deliverImmediately: true)
            other.activate()
        }
        exit(0)
    }

    /// Shows the window when a second copy hands over.
    static func listen() {
        DistributedNotificationCenter.default().addObserver(forName: showWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainWindow.show() }
        }
    }
}
