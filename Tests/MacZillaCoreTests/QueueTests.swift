import Foundation
import Testing
@testable import MacZillaCore

@Suite struct QueueTests {
    private func wait(_ q: TransferQueue, until cond: @Sendable ([TransferJob]) -> Bool) async {
        for await snap in await q.updates() where cond(snap) { return }
    }

    @Test func runsJobsAndReportsResults() async {
        let q = TransferQueue(maxConcurrent: 1)
        await q.enqueue(title: "ok") { progress in progress(10) }
        await q.enqueue(title: "bad") { _ in throw FileProviderError.io("boom") }
        await wait(q) { $0.count == 2 && $0.allSatisfy { $0.state.isFinished } }
        let snap = await q.snapshot()
        #expect(snap[0].state == .done)
        #expect(snap[1].state == .failed("boom"))
    }

    @Test func cancelsRunningJob() async {
        let q = TransferQueue()
        let id = await q.enqueue(title: "long") { _ in try await Task.sleep(for: .seconds(30)) }
        await wait(q) { $0.first?.state == .running }
        await q.cancel(id)
        await wait(q) { $0.first?.state == .cancelled }
        #expect(await q.snapshot().first?.state == .cancelled)
    }

    @Test func retriesTransientErrorsThenSucceeds() async {
        let q = TransferQueue(maxConcurrent: 1, maxRetries: 2, backoff: .milliseconds(10))
        await q.enqueue(title: "flaky") { _ in
            if TransferContext.attempt < 2 { throw FileProviderError.io("net") }
        }
        await wait(q) { $0.first?.state.isFinished == true }
        let job = await q.snapshot()[0]
        #expect(job.state == .done && job.attempt == 2)
    }

    @Test func doesNotRetryPermanentErrors() async {
        let q = TransferQueue(maxConcurrent: 1, maxRetries: 3, backoff: .milliseconds(10))
        await q.enqueue(title: "gone") { _ in throw FileProviderError.notFound("x") }
        await wait(q) { $0.first?.state.isFinished == true }
        let job = await q.snapshot()[0]
        #expect(job.attempt == 0 && job.state == .failed("Nie znaleziono: x"))
    }

    @Test func manualRetryRerunsFailedJob() async {
        let q = TransferQueue(maxConcurrent: 1, maxRetries: 0)
        let counter = Counter()
        let id = await q.enqueue(title: "once") { _ in
            if counter.next() == 1 { throw FileProviderError.io("first") }
        }
        await wait(q) { $0.first?.state.isFinished == true }
        #expect(await q.snapshot()[0].state == .failed("first"))
        await q.retry(id)
        await wait(q) { $0.first?.state == .done }
        #expect(counter.value == 2)
    }

    @Test func pauseAllHoldsNewJobsUntilResumed() async {
        let q = TransferQueue(maxConcurrent: 1)
        await q.pauseAll()
        await q.enqueue(title: "a") { _ in }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await q.snapshot()[0].state == .queued)
        await q.resumeAll()
        await wait(q) { $0.first?.state == .done }
    }

    @Test func heldJobIsSkippedUntilReleased() async {
        let q = TransferQueue(maxConcurrent: 1)
        await q.pauseAll()
        let a = await q.enqueue(title: "a") { _ in }
        await q.hold(a)
        await q.enqueue(title: "b") { _ in }
        await q.resumeAll()
        await wait(q) { $0.count == 2 && $0[1].state == .done }
        #expect(await q.snapshot()[0].state == .paused)
        await q.release(a)
        await wait(q) { $0.first?.state == .done }
    }

    @Test func totalEstimateGivesFraction() async {
        let q = TransferQueue(maxConcurrent: 1)
        await q.enqueue(title: "sized", estimate: { 100 }) { progress in progress(25) }
        await wait(q) { $0.first?.state == .done && $0.first?.bytes == 25 }
        let job = await q.snapshot()[0]
        #expect(job.total == 100 && job.fraction == 0.25)
    }

    @Test func bandwidthLimiterSlowsDown() async {
        let l = BandwidthLimiter()
        await l.setLimit(100_000)
        let t0 = Date()
        for _ in 0..<5 { await l.throttle(10_000) }
        #expect(Date().timeIntervalSince(t0) >= 0.3)
        await l.setLimit(0)
        let t1 = Date()
        await l.throttle(10_000_000)
        #expect(Date().timeIntervalSince(t1) < 0.1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}
