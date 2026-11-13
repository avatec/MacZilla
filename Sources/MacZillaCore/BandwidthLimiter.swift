import Foundation

/// Globalny limit przepustowości transferów (bajty/s; 0 = bez limitu).
public actor BandwidthLimiter {
    public static let shared = BandwidthLimiter()

    private var limit: Int64 = 0
    private var nextFree = Date()

    public func setLimit(_ bytesPerSecond: Int64) { limit = max(0, bytesPerSecond); nextFree = Date() }
    public func currentLimit() -> Int64 { limit }

    /// Wstrzymuje wywołującego tak, by średnia prędkość nie przekraczała limitu.
    public func throttle(_ bytes: Int) async {
        guard limit > 0, bytes > 0 else { return }
        let now = Date()
        let start = max(now, nextFree)
        nextFree = start.addingTimeInterval(Double(bytes) / Double(limit))
        let wait = start.timeIntervalSince(now)
        if wait > 0.001 { try? await Task.sleep(for: .seconds(wait)) }
    }
}
