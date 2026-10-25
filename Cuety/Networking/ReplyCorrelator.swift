import Foundation

/// Matches QLab replies to the requests waiting for them in FIFO order per path.
nonisolated struct ReplyCorrelator<Waiter> {
    private var waiters: [UUID: (key: String, waiter: Waiter)] = [:]
    private var queuedIDs: [String: [UUID]] = [:]
    private var abandonedDeadlines: [String: [ContinuousClock.Instant]] = [:]

    var waitingIDs: [UUID] { Array(waiters.keys) }
    var hasOwedReplies: Bool { abandonedDeadlines.values.contains { !$0.isEmpty } }

    mutating func recordAbandoned(key: String, until deadline: ContinuousClock.Instant) {
        abandonedDeadlines[key, default: []].append(deadline)
    }

    mutating func forgetOwedReplies() {
        abandonedDeadlines.removeAll()
    }

    mutating func pruneOwedReplies(at now: ContinuousClock.Instant) {
        for key in abandonedDeadlines.keys {
            abandonedDeadlines[key]?.removeAll { $0 <= now }
            if abandonedDeadlines[key]?.isEmpty == true {
                abandonedDeadlines.removeValue(forKey: key)
            }
        }
    }

    func mayBeStale(forKey key: String, at now: ContinuousClock.Instant) -> Bool {
        abandonedDeadlines[key]?.contains { $0 > now } == true
    }

    mutating func consumeOwedReply(forKey key: String, at now: ContinuousClock.Instant) -> Bool {
        pruneOwedReplies(at: now)
        guard var deadlines = abandonedDeadlines[key], !deadlines.isEmpty else { return false }
        deadlines.removeFirst()
        if deadlines.isEmpty {
            abandonedDeadlines.removeValue(forKey: key)
        } else {
            abandonedDeadlines[key] = deadlines
        }
        return true
    }

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
}
