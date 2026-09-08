import SwiftUI

/// One entry in the OSC activity log.
///
/// Formatting happens once, here, at capture time rather than on every table
/// redraw — the log can tick over several times a second during a busy cue
/// sequence, and the window may not even be open.
nonisolated struct OSCEvent: Identifiable, Hashable, Sendable {
    enum Direction: Hashable, Sendable {
        case outbound
        case inbound
        /// A packet that arrived but could not be parsed.
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

        /// Kept on the direction rather than in the view, so the table's column
        /// glyphs, the status bar's tallies, and the inspector cannot end up
        /// colouring the same direction three different ways.
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
    /// The OSC address, or a short description for malformed packets.
    let address: String
    /// The arguments rendered for display; empty when there are none.
    let arguments: String
    /// Size of the packet on the wire, before SLIP framing.
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

    /// Builds an entry from a message, splitting address from arguments so the
    /// table can align them in separate columns.
    init(message: OSCMessage, direction: Direction, byteCount: Int, timestamp: Date = Date()) {
        let rendered = message.description
        let argumentText = rendered.hasPrefix(message.address)
            ? String(rendered.dropFirst(message.address.count)).trimmingCharacters(in: .whitespaces)
            : ""
        self.init(
            timestamp: timestamp,
            direction: direction,
            address: message.address,
            arguments: argumentText,
            byteCount: byteCount
        )
    }

    /// A single line suitable for the clipboard.
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

/// A bounded, newest-last log of OSC traffic.
///
/// The capacity cap is the point: a show can run for hours, and an unbounded
/// log would be a slow memory leak in an app that is supposed to be left
/// running all night.
@Observable
final class ActivityLog {
    /// How many entries to retain before dropping the oldest.
    let capacity: Int

    /// Entries in arrival order, oldest first.
    private(set) var entries: [OSCEvent] = []

    /// Total messages seen since launch, including those aged out of `entries`.
    private(set) var totalReceived = 0
    private(set) var totalSent = 0
    private(set) var totalMalformed = 0

    /// Total bytes on the wire, for the connection inspector.
    private(set) var bytesReceived = 0
    private(set) var bytesSent = 0

    /// When paused, counters keep advancing but no entries are retained — so an
    /// operator can freeze the view to read something without losing the tallies.
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

    /// Resets counters as well as entries, when starting a fresh connection.
    func reset() {
        clear()
        totalReceived = 0
        totalSent = 0
        totalMalformed = 0
        bytesReceived = 0
        bytesSent = 0
    }
}
