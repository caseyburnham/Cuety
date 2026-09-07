import SwiftUI

/// A live table of every OSC message sent and received.
///
/// A `Table` rather than a `List`: this is tabular data an operator scans by
/// column, and `Table` gives sortable headers, column resizing, and row
/// selection for free.
struct ActivityLogView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var directionFilter: DirectionFilter = .all
    @State private var selection: Set<OSCEvent.ID> = []
    /// Newest first by default, which is what an operator watching a live
    /// session wants. Clicking a header re-sorts from here.
    @State private var sortOrder = [
        KeyPathComparator(\OSCEvent.timestamp, order: .reverse)
    ]

    private enum DirectionFilter: String, CaseIterable, Identifiable {
        case all, sent, received, malformed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .sent: "Sent"
            case .received: "Received"
            case .malformed: "Malformed"
            }
        }

        func matches(_ direction: OSCEvent.Direction) -> Bool {
            switch self {
            case .all: true
            case .sent: direction == .outbound
            case .received: direction == .inbound
            case .malformed: direction == .malformed
            }
        }
    }

    private var filteredEntries: [OSCEvent] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return model.log.entries
            .filter { entry in
                guard directionFilter.matches(entry.direction) else { return false }
                guard !query.isEmpty else { return true }
                return entry.address.lowercased().contains(query)
                    || entry.arguments.lowercased().contains(query)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(filteredEntries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { entry in
                Image(systemName: entry.direction.systemImage)
                    .foregroundStyle(tint(for: entry.direction))
                    .help(entry.direction.label)
                    .accessibilityLabel(entry.direction.label)
            }
            .width(24)

            TableColumn("Time", value: \.timestamp) { entry in
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80, max: 110)

            TableColumn("Address", value: \.address) { entry in
                Text(entry.address)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Arguments", value: \.arguments) { entry in
                Text(entry.arguments)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 120, ideal: 240)

            TableColumn("Bytes", value: \.byteCount) { entry in
                Text(entry.byteCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .width(min: 50, ideal: 60, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $searchText, prompt: "Filter by address or arguments")
        .overlay {
            if model.log.entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("OSC messages appear here once you connect.")
                )
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $directionFilter) {
                    ForEach(DirectionFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            ToolbarItem {
                Button {
                    model.log.isPaused.toggle()
                } label: {
                    Label(
                        model.log.isPaused ? "Resume" : "Pause",
                        systemImage: model.log.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(model.log.isPaused
                    ? "Resume recording. Counters kept advancing while paused."
                    : "Stop adding rows so you can read them. Counters keep advancing.")
            }

            ToolbarItem {
                Button {
                    copySelection()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selection.isEmpty)
                .help("Copy the selected rows")
            }

            ToolbarItem {
                Button {
                    model.log.clear()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.log.entries.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
    }

    /// Totals stay visible even when the table is filtered or paused, so the
    /// numbers always describe the session rather than the current view.
    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(model.log.totalSent)", systemImage: "arrow.up")
                .help("Messages sent")
            Label("\(model.log.totalReceived)", systemImage: "arrow.down")
                .help("Messages received")

            if model.log.totalMalformed > 0 {
                Label("\(model.log.totalMalformed)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Malformed packets dropped")
            }

            Spacer()

            if model.log.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }

            Text(byteSummary)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var byteSummary: String {
        let sent = model.log.bytesSent.formatted(.byteCount(style: .memory))
        let received = model.log.bytesReceived.formatted(.byteCount(style: .memory))
        return "↑ \(sent)   ↓ \(received)"
    }

    private func tint(for direction: OSCEvent.Direction) -> Color {
        switch direction {
        case .outbound: .blue
        case .inbound: .green
        case .malformed: .orange
        }
    }

    private func copySelection() {
        // Copied in the order they appear on screen, not in log order, so the
        // pasted text matches what was selected.
        let lines = filteredEntries
            .filter { selection.contains($0.id) }
            .map(\.copyableDescription)
        guard !lines.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

#Preview {
    ActivityLogView()
        .environment(AppModel())
        .frame(width: 780, height: 460)
}
