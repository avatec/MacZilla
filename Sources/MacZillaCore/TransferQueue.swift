import Foundation

public enum JobState: Sendable, Equatable {
    case queued, running, paused, done, failed(String), cancelled

    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
}

public struct TransferJob: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public var state: JobState
    public var bytes: Int64
    /// Szacowany rozmiar całości (nil, dopóki nieznany).
    public var total: Int64?
    public var attempt: Int = 0
    public var startedAt: Date?
    public var finishedAt: Date?

    public var fraction: Double? {
        guard let total, total > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytes) / Double(total))
    }

    /// Średnia prędkość (B/s) od startu zadania.
    public func speed(now: Date = Date()) -> Double? {
        guard let startedAt, bytes > 0 else { return nil }
        let dt = (finishedAt ?? now).timeIntervalSince(startedAt)
        return dt > 0.25 ? Double(bytes) / dt : nil
    }

    public func eta(now: Date = Date()) -> TimeInterval? {
        guard state == .running, let total, total > bytes, let s = speed(now: now), s > 0 else { return nil }
        return Double(total - bytes) / s
    }
}

public typealias JobWork = @Sendable (_ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void
public typealias TotalEstimator = @Sendable () async -> Int64?

/// Numer próby bieżącego zadania (0 = pierwsza); dostępny wewnątrz `JobWork`.
public enum TransferContext {
    @TaskLocal public static var attempt = 0
}

/// Kolejka transferów: limit równoległych zadań, postęp, anulowanie, pauza, ponawianie z backoffem.
public actor TransferQueue {
    private var jobs: [UUID: TransferJob] = [:]
    private var order: [UUID] = []
    private var pending: [UUID] = []
    private var works: [UUID: (work: JobWork, estimate: TotalEstimator?)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var running = 0
    private var maxConcurrent: Int
    private let maxRetries: Int
    private let backoff: Duration
    private var paused = false
    private var continuations: [UUID: AsyncStream<[TransferJob]>.Continuation] = [:]

    public init(maxConcurrent: Int = 2, maxRetries: Int = 2, backoff: Duration = .seconds(2)) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxRetries = max(0, maxRetries)
        self.backoff = backoff
    }

    public func setMaxConcurrent(_ n: Int) {
        maxConcurrent = max(1, n)
        pump()
    }

    public func updates() -> AsyncStream<[TransferJob]> {
        let key = UUID()
        let (stream, cont) = AsyncStream<[TransferJob]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[key] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeContinuation(key) } }
        cont.yield(snapshot())
        return stream
    }

    private func removeContinuation(_ key: UUID) { continuations[key] = nil }

    public func snapshot() -> [TransferJob] { order.compactMap { jobs[$0] } }
    public var isPaused: Bool { paused }

    @discardableResult
    public func enqueue(title: String, estimate: TotalEstimator? = nil, work: @escaping JobWork) -> UUID {
        let id = UUID()
        jobs[id] = TransferJob(id: id, title: title, state: .queued, bytes: 0)
        order.append(id)
        works[id] = (work, estimate)
        pending.append(id)
        publish()
        pump()
        return id
    }

    public func cancel(_ id: UUID) {
        if let idx = pending.firstIndex(of: id) {
            pending.remove(at: idx)
            jobs[id]?.state = .cancelled
            jobs[id]?.finishedAt = Date()
            publish()
        } else {
            tasks[id]?.cancel()
        }
    }

    /// Wstrzymuje start nowych zadań (trwające kończą się normalnie).
    public func pauseAll() { paused = true; publish() }
    public func resumeAll() { paused = false; publish(); pump() }

    /// Wstrzymuje/wznawia pojedyncze zadanie oczekujące.
    public func hold(_ id: UUID) {
        guard jobs[id]?.state == .queued else { return }
        jobs[id]?.state = .paused
        publish()
    }

    public func release(_ id: UUID) {
        guard jobs[id]?.state == .paused else { return }
        jobs[id]?.state = .queued
        publish()
        pump()
    }

    /// Ponawia nieudane lub anulowane zadanie od początku.
    public func retry(_ id: UUID) {
        guard let job = jobs[id], job.state.isFinished, job.state != .done, works[id] != nil else { return }
        jobs[id] = TransferJob(id: id, title: job.title, state: .queued, bytes: 0)
        pending.append(id)
        publish()
        pump()
    }

    public func clearFinished() {
        let finished = order.filter { jobs[$0]?.state.isFinished == true }
        for id in finished { works[id] = nil }
        order.removeAll { finished.contains($0) }
        jobs = jobs.filter { order.contains($0.key) }
        publish()
    }

    private func pump() {
        guard !paused else { return }
        while running < maxConcurrent, let idx = pending.firstIndex(where: { jobs[$0]?.state == .queued }) {
            let id = pending.remove(at: idx)
            guard let entry = works[id] else { continue }
            running += 1
            jobs[id]?.state = .running
            jobs[id]?.startedAt = Date()
            publish()
            tasks[id] = Task { [weak self] in
                let report: @Sendable (Int64) -> Void = { [weak self] n in Task { await self?.addBytes(id, n) } }
                if let estimate = entry.estimate, let total = await estimate() { await self?.setTotal(id, total) }
                var attempt = 0
                var result: JobState = .done
                while true {
                    do {
                        try await TransferContext.$attempt.withValue(attempt) { try await entry.work(report) }
                        result = Task.isCancelled ? .cancelled : .done
                        break
                    } catch is CancellationError {
                        result = .cancelled; break
                    } catch {
                        if Task.isCancelled { result = .cancelled; break }
                        guard attempt < (self?.maxRetries ?? 0), Self.isTransient(error) else {
                            result = .failed(error.localizedDescription); break
                        }
                        attempt += 1
                        await self?.beginRetry(id, attempt)
                        do { try await Task.sleep(for: (self?.backoff ?? .seconds(2)) * attempt) }
                        catch { result = .cancelled; break }
                    }
                }
                await self?.finish(id, result)
            }
        }
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error as? FileProviderError {
        case .io?, .notConnected?: return true
        case nil: return (error as NSError).domain == NSPOSIXErrorDomain
        default: return false
        }
    }

    private func setTotal(_ id: UUID, _ total: Int64) { jobs[id]?.total = total; publish() }

    private func beginRetry(_ id: UUID, _ attempt: Int) {
        jobs[id]?.attempt = attempt
        jobs[id]?.bytes = 0
        publish()
    }

    private func addBytes(_ id: UUID, _ n: Int64) {
        jobs[id]?.bytes += n
        publish()
    }

    private func finish(_ id: UUID, _ state: JobState) {
        jobs[id]?.state = state
        jobs[id]?.finishedAt = Date()
        tasks[id] = nil
        running -= 1
        publish()
        pump()
    }

    private func publish() {
        let snap = snapshot()
        for c in continuations.values { c.yield(snap) }
    }
}
