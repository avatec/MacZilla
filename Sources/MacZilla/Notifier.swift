import Foundation
import UserNotifications
import MacZillaCore

/// Powiadomienia systemowe o zakończeniu transferów (działają tylko w spakowanej aplikacji .app).
enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func transfersFinished(_ jobs: [TransferJob]) {
        guard Bundle.main.bundlePath.hasSuffix(".app"), !jobs.isEmpty else { return }
        let failed = jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
        let done = jobs.filter { $0.state == .done }.count
        guard done + failed > 0 else { return }
        let c = UNMutableNotificationContent()
        c.title = Loc.tr(failed == 0 ? "Transfery zakończone" : "Transfery zakończone z błędami")
        c.body = failed == 0 ? Loc.tr("Gotowe: %lld", done) : Loc.tr("Gotowe: %lld, błędy: %lld", done, failed)
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
