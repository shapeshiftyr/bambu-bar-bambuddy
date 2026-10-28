import AppKit
import SwiftUI

/// `--demo printing --fleet --store-media <dir>` renders the Mac App Store media from the scripted demo the README
/// animations use (no printer, no network, nothing saved), then quits:
/// - `<dir>/screenshots`: 2880×1800 PNGs without alpha, a caption over the app's own views drawn at 2x;
/// - `<dir>/preview`: the app preview's frames, 1920×1080 at 30 fps, which `scripts/appstore-media.sh` encodes.
/// The captions are English, like the store listing.
@MainActor
enum StoreMedia {
    static var directory: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--store-media"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1], isDirectory: true)
    }

    static func run(into dir: URL) {
        Task { @MainActor in
            // Let the demo printers report in.
            try? await Task.sleep(for: .seconds(1))
            let store = PrinterStore.shared
            guard let session = store.current, store.hasMultiplePrinters else {
                FileHandle.standardError.write("--store-media needs --demo printing --fleet\n".data(using: .utf8)!)
                exit(1)
            }
            renderScreenshots(into: dir.appendingPathComponent("screenshots"), store: store, session: session)
            if !CommandLine.arguments.contains("--screenshots-only") {
                renderPreview(into: dir.appendingPathComponent("preview"), store: store, session: session)
            }
            print("store media written to \(dir.path)")
            exit(0)
        }
    }

    private static func clock(_ t: Double) -> Date { ReadmeFrames.start.addingTimeInterval(t) }

    // MARK: - Screenshots

    /// 1440×900 points at 2x: 2880×1800, the largest Mac size App Store Connect takes.
    private static let canvas = CGSize(width: 1440, height: 900)

    private static func renderScreenshots(into dir: URL, store: PrinterStore, session: PrinterSession) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot<V: View>(_ name: String, at t: Double, pauseAt: Double? = nil, _ view: V) {
            session.showDemoStatus(ReadmeFrames.status(at: t, pauseAt: pauseAt))
            let framed = view.environment(\.demoClock, clock(t)).environment(\.colorScheme, .dark)
            guard let rep = ReadmeFrames.render(framed, size: canvas, scale: 2) else { return }
            writeOpaque(rep, to: dir.appendingPathComponent("\(name).png"))
        }
        let printer = ShowcasePrinter(store)

        shot("1-menu-bar", at: 2.2, MenuBarShot(store: store, clock: clock(2.2)))
        shot("2-all-printers", at: 2.2, WindowShot(
            store: store, section: .fleet, title: "Every printer. One glance.",
            subtitle: "Run a whole print farm from your Mac. The printer that needs you is always on top."))
        shot("3-widgets", at: 2.2, WidgetsShot(printer: printer, now: clock(2.2), progress: 2.1))
        shot("4-printer", at: 2.2, WindowShot(
            store: store, section: .overview, title: "The whole print, live.",
            subtitle: "A 3D model that prints along, layers, temperatures, fans, and pause, stop, speed and light."))
        shot("5-filament", at: 2.2, WindowShot(
            store: store, section: .filament, title: "Know every spool.",
            subtitle: "AMS trays with colour, material, grams left and humidity, named as Bambu Studio names them."))
        shot("6-alerts", at: 6, pauseAt: 5, AlertsShot(printer: printer, now: clock(6)))
        shot("7-private", at: 2.2, PrivacyShot())
    }

    /// App Store Connect refuses screenshots with an alpha channel.
    private static func writeOpaque(_ rep: NSBitmapImageRep, to url: URL) {
        guard let image = rep.cgImage,
              let flat = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return }
        flat.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let opaque = flat.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: opaque).representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - App preview

    /// 960×540 points at 2x: 1920×1080, the one size App Store Connect takes for Mac app previews.
    private static let previewSize = CGSize(width: 960, height: 540)
    static let previewFPS = 30.0

    private struct Segment {
        var length: Double
        /// Sets the demo status for `t` seconds into the segment and returns what to draw.
        var frame: @MainActor (Double) -> AnyView
    }

    /// 29 seconds (App Store Connect takes 15 to 30): the menu bar, a tour of the window, the widgets, the app.
    private static func renderPreview(into dir: URL, store: PrinterStore, session: PrinterSession) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let printer = ShowcasePrinter(store)
        let pauseAt = 4.6, allAt = 7.0
        // Zoom the menu bar scene so the whole panel stays in frame, in its tallest state.
        var panel: CGFloat = 0
        for (t, all) in [(0.0, false), (pauseAt + 0.5, false), (allAt, true)] {
            session.showDemoStatus(ReadmeFrames.status(at: t, pauseAt: pauseAt))
            panel = max(panel, panelHeight(store, showsAll: all))
        }
        let menuZoom = min(1.25, previewSize.height / (MenuBarScene.panelTop + panel + 20))
        let tour: [(AppSection, Double, String)] = [
            (.overview, 4.0, "The whole print, live in 3D."),
            (.filament, 3.4, "Every spool in your AMS."),
            (.fleet, 3.6, "Your whole print farm at a glance."),
        ]
        let segments = [
            Segment(length: 9.5) { t in
                session.showDemoStatus(ReadmeFrames.status(at: t, pauseAt: pauseAt))
                let caption = t < pauseAt ? "Your print, live in the menu bar." : t < allAt ? "It tells you when it needs you." : "Every printer, one click away."
                let since = t < pauseAt ? t : t < allAt ? t - pauseAt : t - allAt
                return AnyView(PreviewMenuBar(store: store, clock: clock(t), showsAll: t >= allAt, caption: caption, captionAge: since,
                                              zoom: menuZoom))
            },
            Segment(length: tour.reduce(0) { $0 + $1.1 }) { t in
                session.showDemoStatus(ReadmeFrames.status(at: 2 + t * 0.6, pauseAt: nil))
                var begin = 0.0, index = 0
                while index < tour.count - 1 && t >= begin + tour[index].1 { begin += tour[index].1; index += 1 }
                let local = t - begin, fade = 0.45
                let blend = index < tour.count - 1 ? max(0, min(1, (local - (tour[index].1 - fade)) / fade)) : 0
                return AnyView(PreviewWindow(store: store, section: tour[index].0, next: tour[min(index + 1, tour.count - 1)].0,
                                             blend: blend * blend * (3 - 2 * blend), caption: tour[index].2, captionAge: local)
                    .environment(\.demoClock, clock(t)))
            },
            Segment(length: 5.5) { t in
                AnyView(PreviewWidgets(printer: printer, now: clock(t), progress: 2 + t * 0.25, captionAge: t))
            },
            Segment(length: 3) { t in AnyView(PreviewEndCard()) },
        ]
        let fade = 0.35
        var index = 0
        for (number, segment) in segments.enumerated() {
            for i in 0..<Int((segment.length * previewFPS).rounded()) {
                let t = Double(i) / previewFPS
                // Each segment fades in and out over the shared desktop; the first starts in full view.
                let fadeIn = number == 0 ? 1 : min(1, t / fade)
                let fadeOut = number == segments.count - 1 ? 1 : min(1, (segment.length - t) / fade)
                let view = ZStack {
                    DesktopBackdrop()
                    segment.frame(t).opacity(max(0, min(fadeIn, fadeOut)))
                }
                .environment(\.colorScheme, .dark)
                index += 1
                let url = dir.appendingPathComponent(String(format: "frame-%05d.png", index))
                try? ReadmeFrames.render(view, size: previewSize, scale: 2)?.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    /// The menu bar panel's height with the demo status it shows now.
    private static func panelHeight(_ store: PrinterStore, showsAll: Bool) -> CGFloat {
        NSHostingView(rootView: MenuPanel(showsAllOverride: showsAll).environment(store).environment(\.plainPanel, true)
            .environment(\.colorScheme, .dark)).fittingSize.height
    }
}

// MARK: - Pieces

/// The store art's caption: a big headline and a line under it.
private struct Caption: View {
    let title: String
    let subtitle: String?
    var alignment: HorizontalAlignment = .center
    var titleSize: CGFloat = 60
    var width: CGFloat = 1100

    var body: some View {
        VStack(alignment: alignment, spacing: titleSize * 0.28) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .tracking(-titleSize * 0.012)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: titleSize * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(titleSize * 0.06)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
        .foregroundStyle(.white)
        .frame(width: width, alignment: Alignment(horizontal: alignment, vertical: .center))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
    }
}

/// Darkens one side of the desktop so the caption over it reads well.
private struct Scrim: View {
    var from: UnitPoint = .leading
    var to: UnitPoint = .trailing
    var strength = 0.45

    var body: some View {
        LinearGradient(colors: [.black.opacity(strength), .black.opacity(0)], startPoint: from, endPoint: to)
    }
}

private struct AppIcon: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: size * 0.08, y: size * 0.04)
    }
}

/// A widget in its desktop chrome, enlarged.
private struct BigWidget: View {
    let size: WidgetSize
    let snapshot: SharedSnapshot
    let date: Date
    let scale: CGFloat

    var body: some View {
        WidgetFrame(width: size.frame.width, height: size.frame.height) {
            switch size {
            case .small: SmallWidgetView(snapshot: snapshot, date: date)
            case .medium: MediumWidgetView(snapshot: snapshot, date: date)
            case .large: LargeWidgetView(snapshot: snapshot, date: date)
            }
        }
        .scaleEffect(scale)
        .frame(width: size.frame.width * scale, height: size.frame.height * scale)
    }
}

/// Three printers' widgets: the current one printing (large), one paused (medium), one finished and one heating (small).
private struct WidgetTrio: View {
    let printer: ShowcasePrinter
    let now: Date
    /// Seconds into the printing scene, which sets how far the large widget's print is.
    let progress: Double
    let scale: CGFloat

    var body: some View {
        let gap = 24 * scale
        HStack(alignment: .center, spacing: gap * 1.4) {
            VStack(alignment: .leading, spacing: gap) {
                BigWidget(size: .medium, snapshot: other(.paused, at: 0, "A1 Desk", "A1", job: "Gridfinity Baseplate 4x4"),
                          date: now, scale: scale)
                HStack(spacing: gap) {
                    BigWidget(size: .small, snapshot: other(.finished, at: 1, "A1 mini Shelf", "A1 mini", job: "Keychain Batch"),
                              date: now, scale: scale)
                    BigWidget(size: .small, snapshot: other(.preparing, at: 2.6, "H2D Studio", "H2D", job: "Two-tone Vase"),
                              date: now, scale: scale)
                }
            }
            BigWidget(size: .large, snapshot: ShowcaseScene.printing.snapshot(at: progress, now: now, printer: printer), date: now, scale: scale)
        }
    }

    /// The scene on another of the fleet's printers, printing its own job.
    private func other(_ scene: ShowcaseScene, at t: Double, _ name: String, _ model: String, job: String) -> SharedSnapshot {
        var p = printer
        p.name = name
        p.model = model
        var snapshot = scene.snapshot(at: t, now: now, printer: p)
        snapshot.status?.jobName = job
        snapshot.lastJob?.name = job
        return snapshot
    }
}

/// A macOS notification banner from Bambu Bar, as the app posts them.
private struct NotificationBanner: View {
    let title: String
    let message: String
    let time: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIcon(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(time).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 372, alignment: .leading)
        .foregroundStyle(.white)
        // Offscreen rendering skips materials: a dark glass tint over the desktop instead.
        .background(Color(red: 0.17, green: 0.16, blue: 0.17).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

// MARK: - Screenshot layouts

/// The hero: a desktop with the menu bar along the top, Bambu Bar's panel open under its status item.
private struct MenuBarShot: View {
    let store: PrinterStore
    let clock: Date
    private let zoom: CGFloat = 1.55

    var body: some View {
        let scene = CGSize(width: 1440 / zoom, height: 900 / zoom)
        ZStack(alignment: .topLeading) {
            MenuBarScene(store: store, size: scene, clock: clock)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: 1440, height: 900, alignment: .topLeading)
            Scrim(strength: 0.4).frame(width: 760).offset(y: 44)
            VStack(alignment: .leading, spacing: 34) {
                HStack(spacing: 16) {
                    AppIcon(size: 64)
                    Text("Bambu Bar").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                }
                Caption(title: "Your print,\nlive in the\nmenu bar.",
                        subtitle: "Progress, time left, temperatures and filament for your Bambu Lab printer. One click away, no slicer needed.",
                        alignment: .leading, titleSize: 76, width: 600)
            }
            .padding(.leading, 96)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 1440, height: 900, alignment: .topLeading)
        .clipped()
    }
}

/// A caption across the top and the whole window under it.
private struct WindowShot: View {
    let store: PrinterStore
    let section: AppSection
    let title: String
    let subtitle: String
    private let top: CGFloat = 214

    var body: some View {
        ZStack(alignment: .top) {
            DesktopBackdrop()
            Scrim(from: .top, to: .center, strength: 0.35)
            Caption(title: title, subtitle: subtitle).padding(.top, 62)
            FramedWindow(store: store, section: section, next: section)
                .scaleEffect((900 - top - 36) / FramedWindow.standardSize.height, anchor: .top)
                .padding(.top, top)
        }
        .frame(width: 1440, height: 900, alignment: .top)
        .clipped()
    }
}

private struct WidgetsShot: View {
    let printer: ShowcasePrinter
    let now: Date
    let progress: Double

    var body: some View {
        ZStack(alignment: .top) {
            DesktopBackdrop()
            Scrim(from: .top, to: .center, strength: 0.35)
            Caption(title: "Widgets that count down.",
                    subtitle: "Small, medium and large, one for each printer. The print stays in view on your desktop.")
                .padding(.top, 62)
            WidgetTrio(printer: printer, now: now, progress: progress, scale: 1.5)
                .padding(.top, 250)
        }
        .frame(width: 1440, height: 900, alignment: .top)
    }
}

private struct AlertsShot: View {
    let printer: ShowcasePrinter
    let now: Date

    private var runout: String {
        HMSCatalog.shared.hmsText("0700230000020001") ?? "AMS A slot 4 filament has run out. Insert a new spool to continue."
    }
    private var clog: String {
        HMSCatalog.shared.errorText("03004006") ?? "The nozzle is clogged with filament. The print has been stopped."
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DesktopBackdrop()
            Scrim(strength: 0.4).frame(width: 760)
            Caption(title: "Know the moment\nit needs you.",
                    subtitle: "Notifications when a print finishes, fails or runs out of filament, with the printer's error in plain words.",
                    alignment: .leading, titleSize: 70, width: 580)
                .padding(.leading, 96)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 18) {
                NotificationBanner(title: "A1 Desk: Print paused", message: "Gridfinity Baseplate 4x4: \(runout)", time: "now")
                NotificationBanner(title: "X1C Garage: Print failed", message: "Phone Stand: \(clog)", time: "4m ago")
                NotificationBanner(title: "A1 mini Shelf: Print finished",
                                   message: "Keychain Batch finished in 1h 52m. It's ready to take off the plate.", time: "12m ago")
            }
            .scaleEffect(1.55, anchor: .leading)
            .frame(width: 372 * 1.55, alignment: .leading)
            .padding(.leading, 770)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 1440, height: 900, alignment: .topLeading)
        .clipped()
    }
}

/// What sets it apart, as tiles beside the icon.
private struct PrivacyShot: View {
    private let points: [(String, String, String)] = [
        ("server.rack", "From your Bambuddy", "Every printer your own Bambuddy server manages. No cloud in between."),
        ("person.crop.circle.badge.xmark", "No account", "Nothing to sign up for. Your printer can stay bound to your Bambu Lab account."),
        ("hand.raised.fill", "Collects nothing", "No analytics, no tracking. Your API key stays in your keychain."),
        ("leaf.fill", "Light on your Mac", "Under 1% CPU in the background, even while printing."),
        ("arrow.triangle.2.circlepath", "Follows Bambuddy", "Printers added or removed there show up or disappear here."),
        ("globe", "18 languages", "With printer terms as Bambu Studio says them."),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            DesktopBackdrop()
            Color.black.opacity(0.25)
            VStack(spacing: 56) {
                VStack(spacing: 26) {
                    AppIcon(size: 120)
                    Caption(title: "Private by design.", subtitle: "Bambu Bar talks to your printers and nothing else.")
                }
                Grid(horizontalSpacing: 22, verticalSpacing: 22) {
                    GridRow { tile(0); tile(1); tile(2) }
                    GridRow { tile(3); tile(4); tile(5) }
                }
            }
            .padding(.top, 70)
        }
        .frame(width: 1440, height: 900, alignment: .top)
    }

    private func tile(_ i: Int) -> some View {
        let (symbol, title, text) = points[i]
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.printing)
                .frame(height: 32)
            Text(title).font(.system(size: 21, weight: .bold))
            Text(text).font(.system(size: 15.5)).foregroundStyle(.white.opacity(0.78)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(width: 380, height: 168, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(red: 0.12, green: 0.11, blue: 0.12).opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Preview scenes (960×540 points)

/// The caption fading and rising into place as it changes.
private struct PreviewCaption: View {
    let text: String
    let age: Double
    var alignment: HorizontalAlignment = .center
    var width: CGFloat = 860

    var body: some View {
        let e = min(1, age / 0.4)
        let eased = 1 - pow(1 - e, 3)
        Caption(title: text, subtitle: nil, alignment: alignment, titleSize: 38, width: width)
            .opacity(eased)
            .offset(y: (1 - eased) * 10)
    }
}

private struct PreviewMenuBar: View {
    let store: PrinterStore
    let clock: Date
    let showsAll: Bool
    let caption: String
    let captionAge: Double
    let zoom: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuBarScene(store: store, size: CGSize(width: 960 / zoom, height: 540 / zoom), clock: clock, showsAll: showsAll)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: 960, height: 540, alignment: .topLeading)
            Scrim(strength: 0.4).frame(width: 460).offset(y: 33)
            PreviewCaption(text: caption, age: captionAge, alignment: .leading, width: 370)
                .padding(.leading, 52)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 960, height: 540, alignment: .topLeading)
        .clipped()
    }
}

private struct PreviewWindow: View {
    let store: PrinterStore
    let section: AppSection
    let next: AppSection
    let blend: Double
    let caption: String
    let captionAge: Double

    var body: some View {
        ZStack(alignment: .top) {
            Scrim(from: .top, to: .center, strength: 0.3)
            PreviewCaption(text: caption, age: captionAge).padding(.top, 24)
            // The whole window, under the caption.
            FramedWindow(store: store, section: section, next: next, blend: blend)
                .scaleEffect((540 - 82 - 16) / FramedWindow.standardSize.height, anchor: .top)
                .padding(.top, 82)
        }
        .frame(width: 960, height: 540, alignment: .top)
        .clipped()
    }
}

private struct PreviewWidgets: View {
    let printer: ShowcasePrinter
    let now: Date
    let progress: Double
    let captionAge: Double

    var body: some View {
        ZStack(alignment: .top) {
            Scrim(from: .top, to: .center, strength: 0.3)
            PreviewCaption(text: "Widgets that count down on your desktop.", age: captionAge).padding(.top, 26)
            WidgetTrio(printer: printer, now: now, progress: progress, scale: 0.98)
                .padding(.top, 104)
        }
        .frame(width: 960, height: 540, alignment: .top)
    }
}

private struct PreviewEndCard: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 18) {
                AppIcon(size: 128)
                Text("Bambu Bar").font(.system(size: 50, weight: .bold)).foregroundStyle(.white)
                Text("Your Bambu Lab printers, right in the menu bar.")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.82))
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 3)
        }
        .frame(width: 960, height: 540)
    }
}
