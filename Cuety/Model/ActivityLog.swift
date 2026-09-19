import SwiftUI

nonisolated struct OSCEvent: Identifiable, Hashable, Sendable {
    enum Direction: Hashable, Sendable {
        case outbound
        case inbound
        case malformed

        var systemImage: String {
            switch self {
            case .outbound: "arrow.up.circle.fill"
            case .inbound: "arrow.down.circle.fill"
            case .malformed: "exclamationmark.triangle.fill"
            }
        }

        var label: String {
            switch self {
            case .outbound: "Sent"
            case .inbound: "Received"
            case .malformed: "Malformed"
            }
        }

        var tint: Color {
            switch self {
            case .outbound: .blue
            case .inbound: .green
            case .malformed: .orange
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let address: String
    let arguments: String
    let byteCount: Int

    /// Lowercased once here so filtering the log does not renormalise every
    /// retained entry on each keystroke or each new message.
    let searchableAddress: String
    let searchableArguments: String

    init(
        timestamp: Date = Date(),
        direction: Direction,
        address: String,
        arguments: String = "",
        byteCount: Int
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.address = address
        self.arguments = arguments
        self.byteCount = byteCount
        searchableAddress = address.lowercased()
        searchableArguments = arguments.lowercased()
    }

    init(message: OSCMessage, direction: Direction, byteCount: Int, timestamp: Date = Date()) {
        let safe = OSCRedaction.redacting(message)
        let rendered = safe.description
        let argumentText = rendered.hasPrefix(safe.address)
            ? String(rendered.dropFirst(safe.address.count)).trimmingCharacters(in: .whitespaces)
            : ""
        self.init(
            timestamp: timestamp,
            direction: direction,
            address: safe.address,
            arguments: argumentText,
            byteCount: byteCount
        )
    }

    /// `query` is expected to be lowercased already, so a filter pass
    /// normalises the search text once rather than once per entry.
    func matches(lowercasedQuery query: String) -> Bool {
        query.isEmpty
            || searchableAddress.contains(query)
            || searchableArguments.contains(query)
    }

    var copyableDescription: String {
        let time = Self.clipboardFormatter.string(from: timestamp)
        let arrow = direction == .outbound ? "→" : (direction == .inbound ? "←" : "⚠")
        return arguments.isEmpty
            ? "\(time) \(arrow) \(address)"
            : "\(time) \(arrow) \(address) \(arguments)"
    }

    private static let clipboardFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

@Observable
final class ActivityLog {
    let capacity: Int
    let byteCapacity: Int

    /// The only observed part of the log, bumped at most once per
    /// ``flushInterval``. Everything a view reads is registered against it, so
    /// a flood of OSC traffic redraws the UI at a steady rate rather than once
    /// per message.
    private(set) var revision = 0

    /// Roughly 45 redraws a second: fast enough to read as live, slow enough
    /// that the table is not rebuilt for every packet.
    private static let flushInterval = Duration.milliseconds(22)

    @ObservationIgnored private var flushTask: Task<Void, Never>?

    @ObservationIgnored private var storage: [OSCEvent?]
    @ObservationIgnored private var storageHead = 0
    @ObservationIgnored private var storedCount = 0
    @ObservationIgnored private var storedBytes = 0

    /// Bumped whenever the ring buffer changes so ``entries`` linearises it
    /// once per change instead of once per read.
    @ObservationIgnored private var mutationCount = 0
    @ObservationIgnored private var cachedEntries: (mutationCount: Int, value: [OSCEvent])?

    @ObservationIgnored private var counters = Counters()

    /// How many views are showing the log. Nothing is retained while this is
    /// zero: with the window closed there is nobody to read the rows, so the
    /// cost of building and holding them buys nothing.
    @ObservationIgnored private var viewerCount = 0

    private struct Counters {
        var received = 0
        var sent = 0
        var malformed = 0
        var bytesReceived = 0
        var bytesSent = 0
    }

    var entries: [OSCEvent] {
        trackRevision()

        if let cachedEntries, cachedEntries.mutationCount == mutationCount {
            return cachedEntries.value
        }

        var value: [OSCEvent] = []
        if storedCount > 0, capacity > 0 {
            value.reserveCapacity(storedCount)
            for offset in 0..<storedCount {
                if let event = storage[(storageHead + offset) % capacity] {
                    value.append(event)
                }
            }
        }

        cachedEntries = (mutationCount, value)
        return value
    }

    var totalReceived: Int { trackedRevision(counters.received) }
    var totalSent: Int { trackedRevision(counters.sent) }
    var totalMalformed: Int { trackedRevision(counters.malformed) }

    var bytesReceived: Int { trackedRevision(counters.bytesReceived) }
    var bytesSent: Int { trackedRevision(counters.bytesSent) }

    var isPaused = false

    /// `true` while the log is both attached to a view and not paused. The
    /// counters advance either way, so the inspector's totals stay honest.
    var isRetaining: Bool { viewerCount > 0 && !isPaused }

    init(capacity: Int = 2000, byteCapacity: Int = 2_000_000) {
        self.capacity = max(0, capacity)
        self.byteCapacity = max(0, byteCapacity)
        storage = Array(repeating: nil, count: max(0, capacity))
    }

    /// Called by a view as it appears and disappears. A log nobody is showing
    /// records nothing but keeps counting.
    func addViewer() {
        viewerCount += 1
    }

    func removeViewer() {
        viewerCount = max(0, viewerCount - 1)
    }

    func record(
        direction: OSCEvent.Direction,
        byteCount: Int,
        event: @autoclosure () -> OSCEvent
    ) {
        updateTotals(direction: direction, byteCount: byteCount)
        scheduleFlush()
        guard isRetaining, capacity > 0, byteCapacity > 0 else { return }

        let event = event()
        let eventBytes = retainedByteCount(of: event)
        guard eventBytes <= byteCapacity else { return }

        while storedCount > 0,
              (storedCount >= capacity || storedBytes + eventBytes > byteCapacity) {
            removeOldest()
        }

        let index = (storageHead + storedCount) % capacity
        storage[index] = event
        storedCount += 1
        storedBytes += eventBytes
        mutationCount += 1
    }

    func record(_ event: OSCEvent) {
        record(direction: event.direction, byteCount: event.byteCount, event: event)
    }

    func clear() {
        storage = Array(repeating: nil, count: capacity)
        storageHead = 0
        storedCount = 0
        storedBytes = 0
        mutationCount += 1
        flush()
    }

    /// Registers the observed ``revision`` as a dependency of whatever is
    /// being read, so SwiftUI invalidates on the coalesced flush rather than
    /// on every recorded message.
    private func trackRevision() {
        _ = revision
    }

    private func trackedRevision<Value>(_ value: Value) -> Value {
        trackRevision()
        return value
    }

    /// Publishes everything recorded since the last flush.
    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        revision &+= 1
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard let self, !Task.isCancelled else { return }
            flushTask = nil
            revision &+= 1
        }
    }

    private func updateTotals(direction: OSCEvent.Direction, byteCount: Int) {
        switch direction {
        case .outbound:
            counters.sent += 1
            counters.bytesSent += byteCount
        case .inbound:
            counters.received += 1
            counters.bytesReceived += byteCount
        case .malformed:
            counters.malformed += 1
            counters.bytesReceived += byteCount
        }
    }

    private func removeOldest() {
        guard storedCount > 0, capacity > 0 else { return }
        if let event = storage[storageHead] {
            storedBytes -= retainedByteCount(of: event)
        }
        storage[storageHead] = nil
        storageHead = (storageHead + 1) % capacity
        storedCount -= 1
    }

    /// An entry retains its text twice over — once as shown, once normalised
    /// for searching — so the byte cap counts both and still bounds the log's
    /// share of memory.
    private func retainedByteCount(of event: OSCEvent) -> Int {
        (event.address.utf8.count + event.arguments.utf8.count) * 2
    }
}
