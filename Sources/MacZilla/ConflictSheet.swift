import SwiftUI

struct ConflictSheet: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Element „\(app.conflict?.name ?? "")” już istnieje").font(.headline)
                    Text("W miejscu docelowym znajduje się element o tej samej nazwie. Co zrobić?")
                        .foregroundStyle(.secondary)
                    if app.conflict?.allowsOverwriteIfNewer == true {
                        Text("Nadpisywanie zależy od daty modyfikacji pliku źródłowego i docelowego.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if (app.conflict?.remaining ?? 0) > 0 {
                Toggle("Zapamiętaj wybór dla tej sesji wysyłki (pozostało: \(app.conflict?.remaining ?? 0))",
                       isOn: $app.conflictApplyToAll)
            }
            HStack {
                Button("Anuluj") { app.answerConflict(.cancel) }.keyboardShortcut(.cancelAction)
                Spacer()
            }
            HStack {
                Button("Pomiń") { app.answerConflict(.skip) }
                Button("Zachowaj oba") { app.answerConflict(.keepBoth) }
                if app.conflict?.allowsOverwriteIfNewer == true {
                    Button("Nadpisz wszystko") { app.answerConflict(.overwrite) }
                } else {
                    Button("Nadpisz") { app.answerConflict(.overwrite) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            if app.conflict?.allowsOverwriteIfNewer == true {
                Button("Nadpisz tylko nowsze") { app.answerConflict(.overwriteIfNewer) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
