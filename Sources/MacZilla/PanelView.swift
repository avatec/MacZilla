import SwiftUI
import UniformTypeIdentifiers
import MacZillaCore

struct PanelView: View {
    @Bindable var panel: PanelModel
    let side: PanelSide
    @Environment(AppState.self) private var app
    @FocusState.Binding var focus: PanelSide?

    private var isActive: Bool { app.active == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            statusBar
        }
        .background(.background)
        .sheet(isPresented: $showConnect) { SiteManagerSheet(panel: panel) }
        .sheet(isPresented: Binding(get: { permissionTargets != nil }, set: { if !$0 { permissionTargets = nil } })) {
            if let targets = permissionTargets {
                PermissionEditorSheet(items: targets, panel: panel)
            }
        }
        .task { await panel.monitorConnection() }
        .overlay(alignment: .top) {
            Rectangle().fill(isActive ? Color.accentColor : .clear).frame(height: 2)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { Task { await panel.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(!panel.canGoBack)
            Button { Task { await panel.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(!panel.canGoForward)
            Button { Task { await panel.goUp() } } label: { Image(systemName: "arrow.up") }
                .help("Katalog nadrzędny")
            PathField(panel: panel)
            HStack(spacing: 2) {
                Button { showConnect = true } label: { Image(systemName: "server.rack") }
                    .help("Menedżer serwerów")
                Button { Task { await panel.useLocal() } } label: { Image(systemName: "laptopcomputer") }
                    .disabled(panel.provider.id == "local")
                    .help("Ten Mac")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            Toggle(isOn: $panel.showHidden) { Image(systemName: "eye") }
                .toggleStyle(.button)
                .help("Pokaż ukryte pliki")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var table: some View {
        Table(panel.tableItems, selection: $panel.selection, sortOrder: $panel.sortOrder) {
            TableColumn("Nazwa", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: item))
                        .resizable().frame(width: 16, height: 16)
                    Text(item.name).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 240)
            TableColumn("Rozmiar", value: \.sizeSortKey) { item in
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Zmodyfikowano", value: \.dateSortKey) { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Uprawnienia") { item in
                Text(item.permissions.map { String($0, radix: 8) } ?? "")
                    .foregroundStyle(.secondary).monospaced()
            }
            .width(min: 50, ideal: 70)
        }
        .focused($focus, equals: side)
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                if !panel.quickText.isEmpty { panel.cancelQuickSearch(); return .handled }
                return .ignored
            }
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !(press.characters == " " && panel.quickText.isEmpty) else { return .ignored }
            if press.characters == "+" || press.characters == "-" {
                patternAdd = press.characters == "+"
                patternText = "*"
                showPattern = true
                return .handled
            }
            panel.typeAhead(press.characters)
            return .handled
        }
        .alert(patternAdd ? "Zaznacz pliki" : "Odznacz pliki", isPresented: $showPattern) {
            TextField("Wzorzec, np. *.txt", text: $patternText)
            Button("Anuluj", role: .cancel) {}
            Button(patternAdd ? "Zaznacz" : "Odznacz") { panel.select(matching: patternText, add: patternAdd) }
        }        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            if ids.count == 1, let item = panel.items.first(where: { $0.id == ids.first }) {
                Button("Otwórz") { Task { await app.open(item, in: panel) } }
                if !item.isDirectory {
                    Button("Edytuj") { Task { await app.edit(item, in: panel) } }
                    Button("Podgląd") { app.quickLook() }
                }
                Button("Zmień nazwę…") { renameTarget = item }
            }
            if !ids.isEmpty {
                Button("Kopiuj do drugiego panelu") { Task { await app.copySelected() } }
                Button("Przenieś do drugiego panelu") { Task { await app.moveSelected() } }
                if panel.provider.capabilities.contains(.permissions) {
                    Button("Zmień uprawnienia…") {
                        permissionTargets = panel.items.filter { ids.contains($0.id) }
                    }
                }
                Divider()
                Button("Przenieś do kosza") { Task { await app.deleteSelected() } }
            }
            Divider()
            Button("Nowy folder…") { app.showNewFolder = true }
            Button("Odśwież") { Task { await panel.reload() } }
        } primaryAction: { ids in
            if let id = ids.first, let item = panel.tableItem(id: id) {
                Task { await app.open(item, in: panel) }
            }
        }
        .overlay {
            if let err = panel.error {
                ContentUnavailableView("Nie można otworzyć katalogu", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            }
        }
        .alert("Zmień nazwę", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Nazwa", text: $renameText)
            Button("Anuluj", role: .cancel) { renameTarget = nil }
            Button("Zmień") {
                if let t = renameTarget { Task { await app.rename(t, to: renameText) } }
                renameTarget = nil
            }
        }
        .onChange(of: renameTarget) { _, new in renameText = new?.name ?? "" }
    }

    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var permissionTargets: [FileItem]?
    @State private var showConnect = false
    @State private var showPattern = false
    @State private var patternAdd = true
    @State private var patternText = "*"

    private var statusBar: some View {
        HStack {
            let sel = panel.selectedItems
            if sel.isEmpty {
                Text("\(panel.visibleItems.count) elementów")
            } else {
                let total = sel.compactMap(\.size).reduce(0, +)
                Text("Zaznaczono \(sel.count) • \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            }
            Spacer()
            if !panel.quickText.isEmpty {
                Label(panel.quickText, systemImage: "magnifyingglass")
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if panel.isLoading { ProgressView().controlSize(.small) }
            if let status = panel.remoteConnectionStatus {
                Label(status == .connected ? "Połączono" : "Połączenie utracone",
                      systemImage: status == .connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .connected ? .green : .red)
                    .help(panel.connectionIssue ?? (status == .connected ? "Połączenie z serwerem jest aktywne" : "Nie można połączyć się z serwerem"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct PermissionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]
    let panel: PanelModel
    @State private var mode: String
    @State private var permissions: UInt16
    @State private var error: String?
    @State private var applying = false

    init(items: [FileItem], panel: PanelModel) {
        self.items = items
        self.panel = panel
        let initialPermissions = items.first?.permissions ?? 0o644
        _permissions = State(initialValue: initialPermissions)
        _mode = State(initialValue: String(format: "%04o", Int(initialPermissions)))
    }

    private static func parseMode(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.count <= 4, text.allSatisfy({ "01234567".contains($0) }),
              let value = UInt16(text, radix: 8), value <= 0o7777 else { return nil }
        return value
    }

    private var parsedMode: UInt16? { Self.parseMode(mode) }

    private func permissionBinding(_ bit: UInt16) -> Binding<Bool> {
        Binding(
            get: { permissions & bit != 0 },
            set: { enabled in
                if enabled { permissions |= bit } else { permissions &= ~bit }
                mode = String(format: "%04o", Int(permissions))
                error = nil
            })
    }

    private func permissionToggle(_ title: LocalizedStringKey, bit: UInt16) -> some View {
        Toggle(title, isOn: permissionBinding(bit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Uprawnienia: \(items[0].name)" : "Uprawnienia dla \(items.count) elementów")
                .font(.headline)
                .lineLimit(1)
            TextField("Tryb ósemkowy", text: $mode)
                .textFieldStyle(.roundedBorder)
                .onChange(of: mode) { _, newValue in
                    error = nil
                    if let value = Self.parseMode(newValue) { permissions = value }
                }
            Text("Podaj wartość od 0000 do 7777, np. 0644 lub 0755.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    Text("Właściciel")
                    Text("Grupa")
                    Text("Inni")
                }
                .font(.caption.weight(.medium))
                GridRow {
                    Text("Odczyt")
                    permissionToggle("Odczyt", bit: 0o400).labelsHidden().accessibilityLabel("Odczyt — właściciel")
                    permissionToggle("Odczyt", bit: 0o040).labelsHidden().accessibilityLabel("Odczyt — grupa")
                    permissionToggle("Odczyt", bit: 0o004).labelsHidden().accessibilityLabel("Odczyt — inni")
                }
                GridRow {
                    Text("Zapis")
                    permissionToggle("Zapis", bit: 0o200).labelsHidden().accessibilityLabel("Zapis — właściciel")
                    permissionToggle("Zapis", bit: 0o020).labelsHidden().accessibilityLabel("Zapis — grupa")
                    permissionToggle("Zapis", bit: 0o002).labelsHidden().accessibilityLabel("Zapis — inni")
                }
                GridRow {
                    Text("Wykonanie")
                    permissionToggle("Wykonanie", bit: 0o100).labelsHidden().accessibilityLabel("Wykonanie — właściciel")
                    permissionToggle("Wykonanie", bit: 0o010).labelsHidden().accessibilityLabel("Wykonanie — grupa")
                    permissionToggle("Wykonanie", bit: 0o001).labelsHidden().accessibilityLabel("Wykonanie — inni")
                }
            }
            HStack(spacing: 16) {
                permissionToggle("setuid", bit: 0o4000)
                permissionToggle("setgid", bit: 0o2000)
                permissionToggle("sticky", bit: 0o1000)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zastosuj") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedMode == nil || applying)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @MainActor private func apply() async {
        guard let value = parsedMode else { return }
        applying = true
        defer { applying = false }
        do {
            for item in items { try await panel.provider.setPermissions(item.path, mode: value) }
            await panel.reload()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            await panel.reload()
        }
    }
}

struct PathField: View {
    @Bindable var panel: PanelModel
    @State private var text = ""

    var body: some View {
        TextField("Ścieżka", text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await panel.navigate(to: (text as NSString).expandingTildeInPath) } }
            .onAppear { text = panel.path }
            .onChange(of: panel.path) { _, new in text = new }
    }
}

extension FileItem {
    var sizeSortKey: Int64 { size ?? -1 }
    var dateSortKey: Date { modified ?? .distantPast }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        if item.isDirectory { return cached("dir") { NSWorkspace.shared.icon(for: .folder) } }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return cached("ext:" + ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let i = cache[key] { return i }
        let i = make()
        cache[key] = i
        return i
    }
}
