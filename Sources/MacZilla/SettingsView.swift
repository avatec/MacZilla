import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Bindable private var s = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(s: s)
                .tabItem { Label("Ogólne", systemImage: "gearshape") }
            EditorSettings(s: s)
                .tabItem { Label("Edytor", systemImage: "square.and.pencil") }
            TransferSettings(s: s)
                .tabItem { Label("Transfery", systemImage: "arrow.up.arrow.down") }
        }
        .frame(width: 520, height: 400)
        .onChange(of: s.maxConcurrent) { _, _ in Task { await app.applySettings() } }
        .onChange(of: s.bandwidthKBps) { _, _ in Task { await app.applySettings() } }
    }
}

private struct GeneralSettings: View {
    @Bindable var s: AppSettings

    var body: some View {
        Form {
            Picker("Wygląd", selection: $s.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("„Jak w systemie” podąża za ustawieniem macOS; pozostałe wymuszają wygląd tylko w MacZilli.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Język", selection: $s.language) {
                Text("Jak w systemie").tag(AppLanguage.system)
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { Text($0.title).tag($0) }
            }
            Text("Język zmienia się od razu w większości okien; pełna zmiana po ponownym uruchomieniu aplikacji.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Pokazuj ukryte pliki w nowych panelach", isOn: $s.showHiddenByDefault)
            Toggle("Powiadomienia o zakończonych transferach", isOn: $s.notifications)
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Bindable var s: AppSettings
    @State private var newExt = ""

    var body: some View {
        Form {
            Section("Edytor domyślny") {
                LabeledContent("Aplikacja") {
                    HStack {
                        Text(s.editorPath.map(Self.appName) ?? Loc.tr("Domyślna dla typu pliku"))
                            .foregroundStyle(s.editorPath == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Wybierz…") { if let p = Self.chooseApp() { s.editorPath = p } }
                        if s.editorPath != nil { Button("Domyślna") { s.editorPath = nil } }
                    }
                }
                Text("Domyślnie używana jest aplikacja, którą macOS kojarzy z danym formatem (a gdy jej brak – TextEdit).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatycznie wysyłaj zapisane zmiany na serwer", isOn: $s.autoUpload)
            }
            Section("Wyjątki dla rozszerzeń") {
                ForEach(s.editorOverrides.keys.sorted(), id: \.self) { ext in
                    LabeledContent(".\(ext)") {
                        HStack {
                            Text(Self.appName(s.editorOverrides[ext] ?? "")).lineLimit(1)
                            Button { s.editorOverrides[ext] = nil } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Usuń wyjątek")
                        }
                    }
                }
                HStack {
                    TextField("Rozszerzenie", text: $newExt, prompt: Text("np. md"))
                        .frame(maxWidth: 140)
                    Button("Dodaj i wybierz aplikację…") {
                        let ext = newExt.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                        guard !ext.isEmpty, let p = Self.chooseApp() else { return }
                        s.editorOverrides[ext] = p
                        newExt = ""
                    }
                    .disabled(newExt.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func appName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    static func chooseApp() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

private struct TransferSettings: View {
    @Bindable var s: AppSettings

    var body: some View {
        Form {
            Stepper(value: $s.maxConcurrent, in: 1...8) {
                LabeledContent("Równoległe transfery", value: "\(s.maxConcurrent)")
            }
            LabeledContent("Limit prędkości") {
                HStack {
                    TextField("", value: $s.bandwidthKBps, format: .number.grouping(.never), prompt: Text("0"))
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("KB/s")
                }
            }
            Text("0 oznacza brak limitu. Limit dotyczy wszystkich transferów łącznie.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
