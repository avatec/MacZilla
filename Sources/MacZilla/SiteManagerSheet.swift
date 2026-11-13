import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacZillaCore

/// Menedżer serwerów: lista z grupami i wyszukiwarką po lewej, edycja wybranego serwera po prawej (autozapis).
struct SiteManagerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let panel: PanelModel

    @State private var sites: [SiteProfile] = []
    @State private var selection: String?
    @State private var query = ""
    @State private var quickText = ""
    @State private var expanded: Set<String> = []

    @State private var draft = SiteProfile()
    @State private var editingID: UUID?
    @State private var password = ""
    @State private var showPassword = false

    @State private var connecting = false
    @State private var error: String?
    @State private var hostKeyPrompt: HostKeyPrompt?
    @State private var importReport: String?
    @State private var pendingDelete: [UUID] = []
    @State private var renamingFolder: String?
    @State private var renameText = ""

    private struct HostKeyPrompt {
        let host: String
        let key: HostKey
        let changed: Bool
        let resume: CheckedContinuation<Bool, Never>
    }

    private var protocols: [SiteProtocol] { ProviderRegistry.shared.all.map(\.id) }
    private var plugin: ProviderPlugin? { ProviderRegistry.shared.plugin(for: draft.proto) }
    private var tree: [SiteNode] { SiteTree.build(sites, query: query) }
    private var selectedFolder: SiteNode? {
        guard let selection, selection.hasPrefix("folder:") else { return nil }
        return find(selection, in: SiteTree.build(sites))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 860, height: 560)
        .onAppear {
            sites = app.siteStore.load()
            if let first = sites.first { reveal(first); selection = first.id.uuidString }
        }
        .onChange(of: selection) { _, _ in loadSelection() }
        .onChange(of: draft) { _, new in commit(new) }
        .onChange(of: password) { _, new in savePassword(new) }
        .alert(hostKeyPrompt?.changed == true ? "UWAGA: klucz hosta się zmienił" : "Nieznany host",
               isPresented: Binding(get: { hostKeyPrompt != nil }, set: { if !$0 { answerHostKey(false) } })) {
            Button("Anuluj", role: .cancel) { answerHostKey(false) }
            Button(hostKeyPrompt?.changed == true ? "Zastąp klucz i połącz" : "Zaufaj i połącz",
                   role: hostKeyPrompt?.changed == true ? .destructive : nil) { answerHostKey(true) }
        } message: {
            if let p = hostKeyPrompt {
                Text((p.changed
                      ? Loc.tr("Serwer %@ przedstawił inny klucz niż zapisany. Może to oznaczać atak typu man-in-the-middle albo reinstalację serwera.", p.host)
                      : Loc.tr("Nie można zweryfikować autentyczności hosta %@.", p.host))
                     + "\n\n" + Loc.tr("Typ: %@\nOdcisk: %@", p.key.type, p.key.fingerprint))
            }
        }
        .alert("Import z FileZilli", isPresented: Binding(get: { importReport != nil }, set: { if !$0 { importReport = nil } })) {
            Button("OK") { importReport = nil }
        } message: { Text(importReport ?? "") }
        .alert("Zmień nazwę grupy", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Nazwa", text: $renameText)
            Button("Anuluj", role: .cancel) { renamingFolder = nil }
            Button("Zmień") { if let f = renamingFolder { renameFolder(f, to: renameText) }; renamingFolder = nil }
        }
        .confirmationDialog(pendingDelete.count == 1 ? "Usunąć ten serwer?" : "Usunąć \(pendingDelete.count) serwerów?",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) { delete(pendingDelete); pendingDelete = [] }
            Button("Anuluj", role: .cancel) { pendingDelete = [] }
        } message: { Text("Zapisane hasło zostanie usunięte z Keychain.") }
    }

    // MARK: - Pasek boczny

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal").foregroundStyle(.secondary)
                    TextField("Szybkie połączenie", text: $quickText, prompt: Text("user@host:port lub sftp://…"))
                        .textFieldStyle(.plain)
                        .onSubmit { quickConnect() }
                    if !quickText.isEmpty {
                        Button { quickConnect() } label: { Image(systemName: "arrow.right.circle.fill") }
                            .buttonStyle(.borderless).help("Połącz")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Szukaj serwerów", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)

            List(selection: $selection) {
                ForEach(tree) { node in
                    NodeRow(node: node, expanded: $expanded, forceExpand: !query.isEmpty)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first, let s = site(for: id) { connect(s, password: app.keychain.password(for: s.id) ?? "") }
            }
            .overlay {
                if sites.isEmpty {
                    ContentUnavailableView {
                        Label("Brak serwerów", systemImage: "server.rack")
                    } description: {
                        Text("Dodaj serwer lub zaimportuj listę z FileZilli.")
                    }
                } else if tree.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }

            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("Nowy serwer") { addSite(folder: selectedFolder?.folderPath ?? draftFolderForNew) }
                    Divider()
                    importMenu
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Dodaj serwer lub zaimportuj")
                Button { if let id = editingID { pendingDelete = [id] } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(editingID == nil).help("Usuń serwer")
                Spacer()
                Text("\(sites.count) serw.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: 290)
        .background(.background.secondary)
    }

    private var draftFolderForNew: String? { editingID == nil ? nil : draft.folder }

    @ViewBuilder private var importMenu: some View {
        if FileManager.default.fileExists(atPath: FileZillaImporter.defaultFile.path) {
            Button("Importuj z FileZilli (znaleziono instalację)") { importFileZilla(FileZillaImporter.defaultFile) }
        }
        Button("Importuj z FileZilli – wybierz plik XML…") { chooseFileZillaFile() }
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        let siteIDs = ids.compactMap { site(for: $0)?.id }
        if ids.count == 1, let id = ids.first, let s = site(for: id) {
            Button("Połącz") { connect(s, password: app.keychain.password(for: s.id) ?? "") }
            Button("Duplikuj") { duplicate(s) }
            Divider()
        }
        if ids.count == 1, let id = ids.first, id.hasPrefix("folder:"), let n = find(id, in: SiteTree.build(sites)) {
            Button("Nowy serwer w tej grupie") { addSite(folder: n.folderPath) }
            Button("Zmień nazwę grupy…") { renameText = n.name; renamingFolder = n.folderPath }
        }
        if !siteIDs.isEmpty {
            Button("Usuń", role: .destructive) { pendingDelete = siteIDs }
        }
    }

    // MARK: - Szczegóły

    @ViewBuilder private var detail: some View {
        if editingID != nil {
            VStack(spacing: 0) {
                header
                Form {
                    Section("Serwer") {
                        TextField("Nazwa", text: $draft.name, prompt: Text(draft.host.isEmpty ? "np. Serwer klienta" : draft.host))
                        HStack {
                            TextField("Grupa", text: Binding(get: { draft.folder ?? "" },
                                                             set: { draft.folder = $0.isEmpty ? nil : $0 }),
                                      prompt: Text("brak (zagnieżdżanie: Praca/Klienci)"))
                            Menu {
                                Button("Brak grupy") { draft.folder = nil }
                                let all = SiteTree.folderPaths(sites)
                                if !all.isEmpty { Divider() }
                                ForEach(all, id: \.self) { f in Button(f) { draft.folder = f } }
                            } label: { Image(systemName: "folder") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        Picker("Protokół", selection: Binding(get: { draft.proto }, set: changeProtocol)) {
                            ForEach(protocols, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Section("Połączenie") {
                        TextField("Host", text: $draft.host, prompt: Text(plugin?.hostHint.isEmpty == false ? plugin!.hostHint : "np. example.com"))
                        if !draft.host.contains("://") {
                            TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        }
                        TextField("Katalog startowy", text: $draft.startPath, prompt: Text("domyślny"))
                    }
                    Section("Logowanie") {
                        TextField("Użytkownik", text: $draft.username)
                        if plugin?.supportsKeyFile == true {
                            Picker("Tryb logowania", selection: Binding(
                                get: { SFTPAuthMode(rawValue: draft.authMode ?? "") ?? .auto },
                                set: { draft.authMode = $0 == .auto ? nil : $0.rawValue })) {
                                ForEach(SFTPAuthMode.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                            }
                            Text(authHint).font(.caption).foregroundStyle(.secondary)
                        }
                        if authMode != .agent {
                        HStack {
                            let label = Loc.tr(authMode == .key ? "Fraza klucza (opcjonalnie)" : "Hasło")
                            if showPassword { TextField(label, text: $password) } else { SecureField(label, text: $password) }
                            Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless)
                                .help(showPassword ? "Ukryj hasło" : "Pokaż hasło")
                                .accessibilityLabel(showPassword ? "Ukryj hasło" : "Pokaż hasło")
                        }
                        }
                        if plugin?.supportsKeyFile == true, authMode == .key || authMode == .auto {
                            LabeledContent("Plik klucza") {
                                HStack {
                                    Text(draft.identityFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? Loc.tr("domyślne klucze / ssh-agent"))
                                        .foregroundStyle(draft.identityFile == nil ? .secondary : .primary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Button("Wybierz…") { chooseKeyFile() }
                                    if draft.identityFile != nil { Button("Wyczyść") { draft.identityFile = nil } }
                                }
                            }
                        }
                    }
                    if plugin?.supportsCertificateTrust == true {
                        Section("Zabezpieczenia") {
                            Toggle("Ufaj nieprawidłowemu certyfikatowi", isOn: Binding(
                                get: { draft.trustInvalidCertificate ?? false },
                                set: { draft.trustInvalidCertificate = $0 }))
                        }
                    }
                    Section("Notatki") {
                        TextEditor(text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }))
                            .frame(height: 54)
                            .font(.body)
                    }
                }
                .formStyle(.grouped)
                footer
            }
        } else if let folder = selectedFolder {
            ContentUnavailableView {
                Label(folder.name, systemImage: "folder")
            } description: {
                Text("\(folder.siteCount) serwerów w tej grupie")
            } actions: {
                Button("Nowy serwer w grupie") { addSite(folder: folder.folderPath) }
                Button("Zmień nazwę…") { renameText = folder.name; renamingFolder = folder.folderPath }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction).padding(16) }
        } else {
            ContentUnavailableView {
                Label("Menedżer serwerów", systemImage: "server.rack")
            } description: {
                Text("Wybierz serwer z listy, dodaj nowy albo zaimportuj dane z FileZilli.")
            } actions: {
                Button("Nowy serwer") { addSite(folder: nil) }
                Menu("Importuj z FileZilli") { importMenu }.fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction).padding(16) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: draft.proto))
                .font(.system(size: 26)).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title.isEmpty ? Loc.tr("Nowy serwer") : draft.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(draft.host.isEmpty ? Loc.tr("Uzupełnij dane serwera") : "\(draft.proto.rawValue) • \(draft.subtitle)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("Łączenie…").foregroundStyle(.secondary) }
                Spacer()
                Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Połącz") { connect(draft, password: password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.host.isEmpty || connecting)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    static func icon(for proto: SiteProtocol) -> String {
        switch proto {
        case .sftp: return "terminal"
        case .ftps: return "lock.shield"
        case .webdav: return "cloud"
        default: return "externaldrive.connected.to.line.below"
        }
    }

    // MARK: - Wiersze listy

    private struct NodeRow: View {
        let node: SiteNode
        @Binding var expanded: Set<String>
        let forceExpand: Bool

        var body: some View {
            if let site = node.site {
                HStack(spacing: 8) {
                    Image(systemName: SiteManagerSheet.icon(for: site.proto))
                        .frame(width: 22).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.title).lineLimit(1)
                        Text(site.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(node.id)
            } else {
                DisclosureGroup(isExpanded: Binding(
                    get: { forceExpand || expanded.contains(node.id) },
                    set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } })) {
                    ForEach(node.children) { NodeRow(node: $0, expanded: $expanded, forceExpand: forceExpand) }
                } label: {
                    HStack {
                        Label(node.name, systemImage: "folder")
                        Spacer()
                        Text("\(node.siteCount)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(node.id)
            }
        }
    }

    // MARK: - Dane

    private func find(_ id: String, in nodes: [SiteNode]) -> SiteNode? {
        for n in nodes {
            if n.id == id { return n }
            if let hit = find(id, in: n.children) { return hit }
        }
        return nil
    }

    private func site(for id: String) -> SiteProfile? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return sites.first { $0.id == uuid }
    }

    private func reveal(_ site: SiteProfile) {
        var acc: [String] = []
        for c in site.folderComponents { acc.append(c); expanded.insert(SiteNode.folderID(acc.joined(separator: "/"))) }
    }

    private var authMode: SFTPAuthMode {
        plugin?.supportsKeyFile == true ? (SFTPAuthMode(rawValue: draft.authMode ?? "") ?? .auto) : .password
    }

    private var authHint: String {
        switch authMode {
        case .auto: return Loc.tr("Próbuje ssh-agenta i domyślnych kluczy, a następnie hasła, jeśli je podasz.")
        case .password: return Loc.tr("Tylko logowanie hasłem – klucze są ignorowane.")
        case .key: return Loc.tr("Tylko wybrany plik klucza.")
        case .agent: return Loc.tr("Tylko ssh-agent / domyślne klucze, bez hasła.")
        }
    }

    private func loadSelection() {
        error = nil
        if let sel = selection, let s = site(for: sel) {
            draft = s
            editingID = s.id
            password = app.keychain.password(for: s.id) ?? ""
            showPassword = false
        } else {
            editingID = nil
        }
    }

    private func persist() {
        do { try app.siteStore.save(sites) } catch { self.error = error.localizedDescription }
    }

    private func commit(_ new: SiteProfile) {
        guard let i = sites.firstIndex(where: { $0.id == new.id }), sites[i] != new else { return }
        sites[i] = new
        persist()
    }

    private func savePassword(_ new: String) {
        guard let id = editingID else { return }
        let stored = app.keychain.password(for: id) ?? ""
        guard stored != new else { return }
        if new.isEmpty { app.keychain.deletePassword(for: id) } else { try? app.keychain.setPassword(new, for: id) }
    }

    private func changeProtocol(_ new: SiteProtocol) {
        let old = draft.proto
        draft.proto = new
        if draft.port == old.defaultPort { draft.port = new.defaultPort }
    }

    private func addSite(folder: String?) {
        let s = SiteProfile(name: "Nowy serwer", proto: .sftp, folder: folder)
        sites.append(s)
        persist()
        query = ""
        reveal(s)
        selection = s.id.uuidString
    }

    private func duplicate(_ s: SiteProfile) {
        var copy = s
        copy.id = UUID()
        copy.name = s.title + " – kopia"
        sites.append(copy)
        if let pw = app.keychain.password(for: s.id) { try? app.keychain.setPassword(pw, for: copy.id) }
        persist()
        reveal(copy)
        selection = copy.id.uuidString
    }

    private func delete(_ ids: [UUID]) {
        for id in ids { app.keychain.deletePassword(for: id) }
        sites.removeAll { ids.contains($0.id) }
        persist()
        selection = nil
        editingID = nil
    }

    private func renameFolder(_ path: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        var parts = path.split(separator: "/").map(String.init)
        parts[parts.count - 1] = clean
        let newPath = parts.joined(separator: "/")
        for i in sites.indices {
            guard let f = sites[i].folder else { continue }
            if f == path { sites[i].folder = newPath }
            else if f.hasPrefix(path + "/") { sites[i].folder = newPath + f.dropFirst(path.count) }
        }
        persist()
        expanded.insert(SiteNode.folderID(newPath))
        selection = SiteNode.folderID(newPath)
        if let id = editingID, let s = sites.first(where: { $0.id == id }) { draft = s }
    }

    private func chooseKeyFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.prompt = "Wybierz"
        if p.runModal() == .OK, let url = p.url { draft.identityFile = url.path }
    }

    // MARK: - Import z FileZilli

    private func chooseFileZillaFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.allowedContentTypes = [.xml]
        p.message = "Wybierz plik sitemanager.xml (FileZilla: Plik → Eksportuj albo ~/.config/filezilla)"
        let dir = FileZillaImporter.defaultFile.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) { p.directoryURL = dir }
        if p.runModal() == .OK, let url = p.url { importFileZilla(url) }
    }

    private func importFileZilla(_ url: URL) {
        do {
            let result = try FileZillaImporter.parse(Data(contentsOf: url))
            var added = 0, duplicates = 0
            var firstNew: SiteProfile?
            for imp in result.sites {
                let s = imp.site
                if sites.contains(where: { $0.proto == s.proto && $0.host == s.host && $0.port == s.port
                    && $0.username == s.username && $0.name == s.name && $0.folder == s.folder }) {
                    duplicates += 1; continue
                }
                sites.append(s)
                if let pw = imp.password { try? app.keychain.setPassword(pw, for: s.id) }
                firstNew = firstNew ?? s
                added += 1
            }
            persist()
            var lines = [Loc.tr("Zaimportowano serwerów: %lld (grup: %lld).", added, result.folderCount)]
            if duplicates > 0 { lines.append(Loc.tr("Pominięto duplikaty: %lld.", duplicates)) }
            if !result.skipped.isEmpty {
                lines.append("\n" + Loc.tr("Nieobsługiwane (%lld):", result.skipped.count))
                lines += result.skipped.prefix(6).map { "• " + $0 }
            }
            if result.opportunisticFTPCount > 0 {
                lines.append("\n" + Loc.tr("%lld serwerów miało w FileZilli „FTP” – FileZilla włącza tam TLS, jeśli serwer go oferuje. MacZilla łączy się przez zwykłe FTP; dla szyfrowania zmień protokół na FTPS.", result.opportunisticFTPCount))
            }
            if !result.warnings.isEmpty {
                lines.append("\n" + Loc.tr("Uwagi:"))
                lines += result.warnings.prefix(6).map { "• " + $0 }
                if result.warnings.count > 6 { lines.append(Loc.tr("• …i %lld więcej", result.warnings.count - 6)) }
            }
            importReport = lines.joined(separator: "\n")
            if let s = firstNew { reveal(s) }
        } catch {
            importReport = Loc.tr("Nie udało się zaimportować: %@", error.localizedDescription)
        }
    }

    // MARK: - Łączenie

    private func quickConnect() {
        guard let parsed = QuickConnect.parse(quickText, defaultProtocol: editingID == nil ? .sftp : draft.proto) else {
            error = Loc.tr("Nie rozpoznano adresu. Użyj np. user@host:22 albo sftp://user@host/ścieżka.")
            return
        }
        error = nil
        connect(parsed.site, password: parsed.password)
    }

    private func connect(_ site: SiteProfile, password pass: String) {
        guard !connecting else { return }
        connecting = true
        error = nil
        Task {
            if site.proto == .sftp, !(await verifyHostKey(host: site.host, port: site.port)) {
                connecting = false
                return
            }
            do {
                let provider = try ProviderRegistry.shared.makeProvider(for: site, password: pass)
                try await panel.connect(provider)
                if !site.startPath.isEmpty { await panel.navigate(to: site.startPath) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }

    /// true, gdy klucz jest zaufany (lub użytkownik właśnie go zaakceptował).
    private func verifyHostKey(host: String, port: Int) async -> Bool {
        let verifier = HostKeyVerifier()
        do {
            switch try await verifier.check(host: host, port: port) {
            case .trusted:
                return true
            case .unknown(let key):
                return try await askAndTrust(verifier, key, host: host, port: port, changed: false)
            case .changed(let key):
                return try await askAndTrust(verifier, key, host: host, port: port, changed: true)
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func askAndTrust(_ v: HostKeyVerifier, _ key: HostKey, host: String, port: Int, changed: Bool) async throws -> Bool {
        let accepted = await withCheckedContinuation { cont in
            hostKeyPrompt = HostKeyPrompt(host: host, key: key, changed: changed, resume: cont)
        }
        guard accepted else { return false }
        try await v.trust(key, host: host, port: port, replacing: changed)
        return true
    }

    private func answerHostKey(_ accept: Bool) {
        let p = hostKeyPrompt
        hostKeyPrompt = nil
        p?.resume.resume(returning: accept)
    }
}
