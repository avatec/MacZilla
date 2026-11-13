import SwiftUI
import UniformTypeIdentifiers
import MacZillaCore

struct ContentView: View {
    @Environment(AppState.self) private var app
    @FocusState private var focus: PanelSide?
    @State private var folderName = ""

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HSplitView {
                PanelView(panel: app.left, side: .left, focus: $focus)
                    .frame(minWidth: 320)
                PanelView(panel: app.right, side: .right, focus: $focus)
                    .frame(minWidth: 320)
            }
            Divider()
            if !app.jobs.isEmpty {
                TransfersView()
                Divider()
            }
            FunctionBar()
        }
        .frame(minWidth: 800, minHeight: 440)
        .task { await app.start(); focus = .left }
        .onChange(of: focus) { _, new in if let new { app.active = new } }
        .onChange(of: app.active) { _, new in if focus != new { focus = new } }
        .alert("Błąd", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK") { app.alert = nil }
        } message: { Text(app.alert ?? "") }
        .alert("Nowy folder", isPresented: $app.showNewFolder) {
            TextField("Nazwa", text: $folderName)
            Button("Anuluj", role: .cancel) { folderName = "" }
            Button("Utwórz") {
                let n = folderName; folderName = ""
                if !n.isEmpty { Task { await app.makeDirectory(named: n) } }
            }
        }
        .sheet(isPresented: Binding(get: { app.conflict != nil }, set: { _ in })) {
            ConflictSheet()
        }
        .overlay(alignment: .bottom) {
            if app.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.bottom, 44) }
        }
    }
}

struct FunctionBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            key("F3", "Podgląd", .f3) { app.quickLook() }
            key("F4", "Edytuj", .f4) { Task { await app.edit() } }
            key("F5", "Kopiuj", .f5) { Task { await app.copySelected() } }
            key("F6", "Przenieś", .f6) { Task { await app.moveSelected() } }
            key("F7", "Nowy folder", .f7) { app.showNewFolder = true }
            key("F8", "Kosz", .f8) { Task { await app.deleteSelected() } }
        }
        .padding(8)
        .background(.bar)
    }

    private func key(_ k: String, _ title: LocalizedStringKey, _ equiv: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(k).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(equiv, modifiers: [])
        .controlSize(.large)
    }
}

extension KeyEquivalent {
    private static func fn(_ code: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(code)!)) }
    static let f3 = fn(0xF706)
    static let f4 = fn(0xF707)
    static let f5 = fn(0xF708)
    static let f6 = fn(0xF709)
    static let f7 = fn(0xF70A)
    static let f8 = fn(0xF70B)
}
