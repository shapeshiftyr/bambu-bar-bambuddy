import SwiftUI

/// Switches which printer the panel and window show. Each entry has the printer's state; "Bambuddy Server…" at the end.
struct PrinterPicker<Label: View>: View {
    @Environment(PrinterStore.self) private var store
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            ForEach(store.sessions) { session in
                Button {
                    store.select(session.id)
                } label: {
                    if session.id == store.current?.id {
                        SwiftUI.Label("\(session.config.name) — \(session.shortState)", systemImage: "checkmark")
                    } else {
                        Text("\(session.config.name) — \(session.shortState)")
                    }
                }
            }
            Divider()
            Button("Bambuddy Server…") { MainWindow.show(.printers) }
        } label: {
            label
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A dot in the colour of a printer's state.
struct SessionDot: View {
    var session: PrinterSession

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        guard let status = session.status, session.isOnline else {
            return session.phase == .connecting ? Palette.paused : Palette.failed.opacity(0.8)
        }
        return Palette.color(for: status)
    }
}

/// The selector at the top of the window's sidebar: the drawn printer, its name and state.
struct SidebarPrinterPicker: View {
    @Environment(PrinterStore.self) private var store

    var body: some View {
        if let current = store.current {
            PrinterPicker {
                HStack(spacing: 10) {
                    PrinterArt(status: current.status, model: current.config.modelName, dimmed: !current.isOnline, animated: false)
                        .frame(width: 26, height: 31)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.config.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            SessionDot(session: current)
                            Text(current.shortState).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: 186)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .help("Choose a printer")
        }
    }
}
