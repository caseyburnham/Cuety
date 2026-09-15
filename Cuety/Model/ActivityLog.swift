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

    private(set) var entries: [OSCEvent] = []

    private(set) var totalReceived = 0
    private(set) var totalSent = 0
    private(set) var totalMalformed = 0

    private(set) var bytesReceived = 0
    private(set) var bytesSent = 0

    var isPaused = false

    init(capacity: Int = 2000) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    func record(_ event: OSCEvent) {
        switch event.direction {
        case .outbound:
            totalSent += 1
            bytesSent += event.byteCount
        case .inbound:
            totalReceived += 1
            bytesReceived += event.byteCount
        case .malformed:
            totalMalformed += 1
            bytesReceived += event.byteCount
        }

        guard !isPaused else { return }

        entries.append(event)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func reset() {
        clear()
        totalReceived = 0
        totalSent = 0
        totalMalformed = 0
        bytesReceived = 0
        bytesSent = 0
    }
}
