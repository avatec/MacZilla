import SwiftUI
import AppKit

@main
struct MacZillaApp: App {
    @State private var state = AppState()
    private let settings = AppSettings.shared

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppSettings.shared.applyAppearance()
    }

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Autor: Grzegorz Miskiewicz\nwww.avatec.pl",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        let link = (credits.string as NSString).range(of: "www.avatec.pl")
        credits.addAttribute(.link, value: URL(string: "https://www.avatec.pl")!, range: link)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacZilla",
            .applicationVersion: "1.0",
            .version: "",
            .credits: credits,
        ])
    }

    var body: some Scene {
        WindowGroup("MacZilla") {
            ContentView().environment(state)
                .environment(\.locale, settings.locale)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("O programie MacZilla") { Self.showAbout() }
            }
            CommandMenu("Panele") {
                Button("Przełącz panel") { state.active = state.active == .left ? .right : .left }
                    .keyboardShortcut("\t", modifiers: .option)
                Button("Odśwież") { Task { await state.activePanel.reload() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Katalog nadrzędny") { Task { await state.activePanel.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
        Settings {
            SettingsView().environment(state).environment(\.locale, settings.locale)
        }
    }
}
