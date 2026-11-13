import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "Jak w systemie"
        case .light: return "Jasny"
        case .dark: return "Ciemny"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, pl, en
    var id: String { rawValue }
    /// Nazwy języków zostają we własnym języku (nie są tłumaczone).
    var title: String {
        switch self {
        case .system: return ""
        case .pl: return "Polski"
        case .en: return "English"
        }
    }
    var locale: Locale { self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue) }
}

/// Ustawienia globalne aplikacji (UserDefaults).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    var language: AppLanguage {
        didSet {
            d.set(language.rawValue, forKey: "language")
            if language == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([language.rawValue], forKey: "AppleLanguages") }
        }
    }
    /// Ścieżka .app wybranego edytora; nil = domyślna aplikacja systemu dla danego typu pliku.
    var editorPath: String? { didSet { d.set(editorPath, forKey: "editorPath") } }
    /// Wyjątki: rozszerzenie (małe litery, bez kropki) → ścieżka .app.
    var editorOverrides: [String: String] { didSet { d.set(editorOverrides, forKey: "editorOverrides") } }
    var autoUpload: Bool { didSet { d.set(autoUpload, forKey: "autoUpload") } }
    var maxConcurrent: Int { didSet { d.set(maxConcurrent, forKey: "maxConcurrent") } }
    var bandwidthKBps: Int { didSet { d.set(bandwidthKBps, forKey: "bandwidthKBps") } }
    var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    var showHiddenByDefault: Bool { didSet { d.set(showHiddenByDefault, forKey: "showHidden") } }

    var locale: Locale { language.locale }

    private init() {
        let d = UserDefaults.standard
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        editorPath = d.string(forKey: "editorPath")
        editorOverrides = d.dictionary(forKey: "editorOverrides") as? [String: String] ?? [:]
        autoUpload = d.object(forKey: "autoUpload") as? Bool ?? true
        maxConcurrent = max(1, d.object(forKey: "maxConcurrent") as? Int ?? 2)
        bandwidthKBps = max(0, d.integer(forKey: "bandwidthKBps"))
        notifications = d.object(forKey: "notifications") as? Bool ?? true
        showHiddenByDefault = d.bool(forKey: "showHidden")
    }

    func applyAppearance() { NSApp?.appearance = appearance.nsAppearance }

    /// Edytor dla pliku: wyjątek dla rozszerzenia → edytor globalny → domyślna aplikacja systemu → TextEdit.
    func editorURL(for file: URL) -> URL {
        let ext = file.pathExtension.lowercased()
        if let p = editorOverrides[ext], FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let p = editorPath, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let u = NSWorkspace.shared.urlForApplication(toOpen: file) { return u }
        return URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    }

    func openInEditor(_ file: URL) {
        let app = editorURL(for: file)
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

/// Tłumaczenia dla tekstów budowanych w kodzie (klucz = polski tekst; brak tłumaczenia → klucz).
enum Loc {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let code = UserDefaults.standard.string(forKey: "language") ?? "system"
        var bundle = Bundle.main
        if code != "system", let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) { bundle = b }
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? format : String(format: format, locale: Locale(identifier: code == "system" ? "pl" : code), arguments: args)
    }
}
