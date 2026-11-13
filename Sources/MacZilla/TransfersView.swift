import SwiftUI
import MacZillaCore

struct TransfersView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Transfery").font(.headline)
                if app.queuePaused {
                    Label("Wstrzymane", systemImage: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if let speed = totalSpeed {
                    Text(Format.speed(speed)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button {
                    Task { app.queuePaused ? await app.queue.resumeAll() : await app.queue.pauseAll(); await app.refreshQueueState() }
                } label: {
                    Label(app.queuePaused ? "Wznów kolejkę" : "Wstrzymaj kolejkę",
                          systemImage: app.queuePaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless).font(.caption)
                Button("Wyczyść zakończone") { Task { await app.queue.clearFinished() } }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            List(app.jobs) { job in
                JobRow(job: job)
            }
            .listStyle(.plain)
        }
        .frame(height: 150)
        .background(.background)
    }

    private var totalSpeed: Double? {
        let s = app.jobs.filter { $0.state == .running }.compactMap { $0.speed() }
        return s.isEmpty ? nil : s.reduce(0, +)
    }
}

private struct JobRow: View {
    @Environment(AppState.self) private var app
    let job: TransferJob

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).lineLimit(1)
                if job.state == .running || job.state == .queued || job.state == .paused {
                    if let f = job.fraction {
                        ProgressView(value: f).controlSize(.small)
                    } else if job.state == .running {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if case .failed = job.state { Button { Task { await app.queue.retry(job.id) } } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.borderless).help("Ponów") }
            if job.state == .cancelled { Button { Task { await app.queue.retry(job.id) } } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.borderless).help("Ponów") }
            if job.state == .queued { Button { Task { await app.queue.hold(job.id) } } label: { Image(systemName: "pause.circle.fill") }
                .buttonStyle(.borderless).help("Wstrzymaj to zadanie") }
            if job.state == .paused { Button { Task { await app.queue.release(job.id) } } label: { Image(systemName: "play.circle.fill") }
                .buttonStyle(.borderless).help("Wznów to zadanie") }
            if !job.state.isFinished {
                Button { Task { await app.queue.cancel(job.id) } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Anuluj")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch job.state {
        case .queued: return Loc.tr("Oczekuje")
        case .paused: return Loc.tr("Wstrzymane")
        case .done: return Loc.tr("Gotowe") + " • " + Format.bytes(job.bytes)
        case .cancelled: return Loc.tr("Anulowane")
        case .failed(let m): return m
        case .running:
            var parts: [String] = []
            if let t = job.total, t > 0 {
                parts.append(Loc.tr("%@ z %@ (%lld%%)", Format.bytes(job.bytes), Format.bytes(t), Int((job.fraction ?? 0) * 100)))
            } else {
                parts.append(Format.bytes(job.bytes))
            }
            if let s = job.speed() { parts.append(Format.speed(s)) }
            if let e = job.eta() { parts.append(Loc.tr("pozostało %@", Format.duration(e))) }
            if job.attempt > 0 { parts.append(Loc.tr("próba %lld", job.attempt + 1)) }
            return parts.joined(separator: " • ")
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func speed(_ bps: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s" }
    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
}
