import ShowControlCore
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
    private let rawArguments: [OSCValue]
    private let explicitArguments: String?
    let byteCount: Int
    /// Estimated memory footprint in bytes (text plus search normalization),
    /// precomputed without formatting ``rawArguments`` into a string.
    let retainedByteCount: Int

    var arguments: String {
        if let explicitArguments { return explicitArguments }
        guard !rawArguments.isEmpty else { return "" }
        return rawArguments.map(Self.render).joined(separator: " ")
    }

    private static func render(_ value: OSCValue) -> String {
        switch value {
        case .int32(let value): String(value)
        case .int64(let value): String(value)
        case .float32(let value): String(value)
        case .double(let value): String(value)
        case .string(let value), .symbol(let value): "\"\(value)\""
        case .blob(let data): "<\(data.count) bytes>"
        case .timeTag(let tag): tag.isImmediate ? "immediate" : String(tag.rawValue)
        case .true: "true"
        case .false: "false"
        case .null: "nil"
        case .impulse: "impulse"
        case .array(let values): "[" + values.map(Self.render).joined(separator: " ") + "]"
        }
    }

    private static func estimatedRenderedUTF8Count(of values: [OSCValue]) -> Int {
        guard !values.isEmpty else { return 0 }
        var total = values.count - 1
        for value in values {
            total += estimatedRenderedUTF8Count(of: value)
        }
        return total
    }

    private static func estimatedRenderedUTF8Count(of value: OSCValue) -> Int {
        switch value {
        case .int32(let v): decimalByteCount(Int64(v))
        case .int64(let v): decimalByteCount(v)
        case .float32, .double: 12
        case .string(let v), .symbol(let v): v.utf8.count + 2
        case .blob(let data): 8 + decimalByteCount(Int64(data.count))
        case .timeTag(let tag): tag.isImmediate ? 9 : decimalByteCount(tag.rawValue)
        case .true: 4
        case .false: 5
        case .null: 3
        case .impulse: 7
        case .array(let values): 2 + estimatedRenderedUTF8Count(of: values)
        }
    }

    private static func decimalByteCount(_ value: Int64) -> Int {
        if value == 0 { return 1 }
        let negative = value < 0
        let magnitude = value.magnitude
        return (negative ? 1 : 0) + decimalByteCount(magnitude)
    }

    private static func decimalByteCount(_ value: UInt64) -> Int {
        if value < 10 { return 1 }
        var count = 0
        var n = value
        while n > 0 {
            n /= 10
            count += 1
        }
        return count
    }

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
        self.rawArguments = []
        self.explicitArguments = arguments
        self.byteCount = byteCount
        self.retainedByteCount = (address.utf8.count + arguments.utf8.count) * 2
    }

    init(message: OSCMessage, direction: Direction, byteCount: Int, timestamp: Date = Date()) {
        let safe = OSCRedaction.redacting(message)
        self.timestamp = timestamp
        self.direction = direction
        self.address = safe.address
        self.rawArguments = safe.arguments
        self.explicitArguments = nil
        self.byteCount = byteCount
        self.retainedByteCount = (
            safe.address.utf8.count + Self.estimatedRenderedUTF8Count(of: safe.arguments)
        ) * 2
    }

    func matches(lowercasedQuery query: String) -> Bool {
        query.isEmpty
            || address.localizedStandardContains(query)
            || arguments.localizedStandardContains(query)
    }

    var copyableDescription: String {
        let time = timestamp.formatted(Self.clipboardFormat)
        let arrow = direction == .outbound ? "→" : (direction == .inbound ? "←" : "⚠")
        return arguments.isEmpty
            ? "\(time) \(arrow) \(address)"
            : "\(time) \(arrow) \(address) \(arguments)"
    }

    /// A fixed 24-hour format, whatever the person's clock preference, so
    /// copied rows line up and sort.
    private static let clipboardFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )
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
    @ObservationIgnored private var isObservedSinceLastFlush = false

    @ObservationIgnored private var storage: [OSCEvent?]
    @ObservationIgnored private var storageHead = 0
    @ObservationIgnored private var storedCount = 0
    @ObservationIgnored private var storedBytes = 0

    /// Bumped whenever the ring buffer changes so ``entries`` linearises it
    /// once per change instead of once per read.
    @ObservationIgnored private var mutationCount = 0
    @ObservationIgnored private var cachedEntries: (mutationCount: Int, value: [OSCEvent])?

    @ObservationIgnored private var counters = Counters()

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

    /// Changes only when the retained rows do. Counters advance on every
    /// message, paused or not, so caches of the rows key on this rather than
    /// on ``revision``.
    var entriesVersion: Int { trackedRevision(mutationCount) }

    var totalReceived: Int { trackedRevision(counters.received) }
    var totalSent: Int { trackedRevision(counters.sent) }
    var totalMalformed: Int { trackedRevision(counters.malformed) }

    var bytesReceived: Int { trackedRevision(counters.bytesReceived) }
    var bytesSent: Int { trackedRevision(counters.bytesSent) }

    var isPaused = false

    init(capacity: Int = 2000, byteCapacity: Int = 2_000_000) {
        self.capacity = max(0, capacity)
        self.byteCapacity = max(0, byteCapacity)
        storage = Array(repeating: nil, count: max(0, capacity))
    }

    /// Rows are kept whether or not the Activity Log window is open, so
    /// opening it after something goes wrong shows what led up to it. Only
    /// pausing stops rows arriving; the counters advance either way, so the
    /// inspector's totals stay honest.
    func record(
        direction: OSCEvent.Direction,
        byteCount: Int,
        isHeartbeat: Bool = false,
        event: @autoclosure () -> OSCEvent
    ) {
        guard !isHeartbeat else { return }

        updateTotals(direction: direction, byteCount: byteCount)
        scheduleFlush()
        guard !isPaused, capacity > 0, byteCapacity > 0 else { return }
        let event = event()
        let eventBytes = event.retainedByteCount
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
        cachedEntries = nil
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
        cachedEntries = nil
        flush()
    }

    /// Registers the observed ``revision`` as a dependency of whatever is
    /// being read, so SwiftUI invalidates on the coalesced flush rather than
    /// on every recorded message.
    private func trackRevision() {
        isObservedSinceLastFlush = true
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
        isObservedSinceLastFlush = false
        revision &+= 1
    }

    private func scheduleFlush() {
        guard isObservedSinceLastFlush, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.isObservedSinceLastFlush = false
            self.revision &+= 1
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
            storedBytes -= event.retainedByteCount
        }
        storage[storageHead] = nil
        storageHead = (storageHead + 1) % capacity
        storedCount -= 1
    }
}
