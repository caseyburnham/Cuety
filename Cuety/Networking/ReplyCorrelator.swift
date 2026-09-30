import Foundation

/// Matches QLab replies to the requests waiting for them.
///
/// QLab echoes only the request's path, never an ID, so requests wait in a
/// queue per correlation key and a reply goes to the oldest. A request that
/// timed out still has its answer owed until a deadline; while one is owed, a
/// reply on that key may be that older answer rather than the current one.
///
/// A plain value with the clock passed in, so the rules can be tested without
/// a connection; the client owns the timers that drive it.
nonisolated struct ReplyCorrelator<Waiter> {
    private var waiters: [UUID: (key: String, waiter: Waiter)] = [:]
    private var queuedIDs: [String: [UUID]] = [:]
    private var owedUntil: [String: [ContinuousClock.Instant]] = [:]

    var waitingIDs: [UUID] { Array(waiters.keys) }

    var hasOwedReplies: Bool { !owedUntil.isEmpty }

    mutating func register(_ id: UUID, key: String, waiter: Waiter) {
        waiters[id] = (key, waiter)
        queuedIDs[key, default: []].append(id)
    }

    func isWaiting(_ id: UUID) -> Bool {
        waiters[id] != nil
    }

    /// The request a reply on `key` answers: the one that has waited longest.
    func firstWaiting(forKey key: String) -> UUID? {
        queuedIDs[key]?.first
    }

    mutating func remove(_ id: UUID) -> (key: String, waiter: Waiter)? {
        guard let entry = waiters.removeValue(forKey: id) else { return nil }
        queuedIDs[entry.key]?.removeAll { $0 == id }
        if queuedIDs[entry.key]?.isEmpty == true {
            queuedIDs.removeValue(forKey: entry.key)
        }
        return entry
    }

    /// Records that a request on `key` gave up while its answer may still come.
    mutating func recordAbandoned(key: String, until deadline: ContinuousClock.Instant) {
        owedUntil[key, default: []].append(deadline)
    }

    /// Whether a reply on `key` arriving now might answer an abandoned request.
    func mayBeStale(forKey key: String, at now: ContinuousClock.Instant) -> Bool {
        owedUntil[key]?.contains { $0 >= now } ?? false
    }

    /// Accounts for a reply nobody is waiting for. Returns whether it was an
    /// answer still owed to an abandoned request.
    mutating func consumeOwedReply(forKey key: String, at now: ContinuousClock.Instant) -> Bool {
        guard var deadlines = owedUntil[key] else { return false }
        deadlines.removeAll { $0 < now }
        defer { owedUntil[key] = deadlines.isEmpty ? nil : deadlines }

        guard !deadlines.isEmpty else { return false }
        deadlines.removeFirst()
        return true
    }

    /// Drops answers whose deadlines have passed.
    mutating func pruneOwedReplies(at now: ContinuousClock.Instant) {
        for key in owedUntil.keys {
            owedUntil[key]?.removeAll { $0 <= now }
            if owedUntil[key]?.isEmpty == true {
                owedUntil.removeValue(forKey: key)
            }
        }
    }

    mutating func forgetOwedReplies() {
        owedUntil.removeAll()
    }
}
