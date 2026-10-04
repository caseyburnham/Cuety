import ShowControlUI
import SwiftUI

/// Holds the activity log's filter state and turns the log's entries into the
/// rows the table shows. The result is cached against the log's rows and the
/// filter inputs, so a burst of traffic filters and sorts once per redraw
/// rather than once per message, and a paused log not at all.
@MainActor
@Observable
final class ActivityLogPresenter {
    enum Mode: String, CaseIterable, Identifiable {
        case messages
        case events

        var id: String { rawValue }

        var title: String {
            switch self {
            case .messages: "Messages"
            case .events: "Events"
            }
        }
    }

    enum DirectionFilter: String, CaseIterable, Identifiable {
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

    struct Snapshot {
        let allEntries: [OSCEvent]
        let filteredEntries: [OSCEvent]
        let query: String
        let isFiltered: Bool
    }

    var searchText = ""
    var mode: Mode = .messages
    var directionFilter: DirectionFilter = .all
    var sortOrder = [KeyPathComparator(\OSCEvent.timestamp, order: .reverse)]

    private struct CacheKey: Equatable {
        let entriesVersion: Int
        let query: String
        let directionFilter: DirectionFilter
        let sortOrder: [KeyPathComparator<OSCEvent>]
    }

    @ObservationIgnored private var cache: (key: CacheKey, snapshot: Snapshot)?

    /// Entries are immutable, so an entry's formatted arguments can be kept
    /// for as long as it stays selected.
    @ObservationIgnored private var inspectedArguments: (id: OSCEvent.ID, text: String)?

    func snapshot(of log: ActivityLog) -> Snapshot {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let key = CacheKey(
            entriesVersion: log.entriesVersion,
            query: query,
            directionFilter: directionFilter,
            sortOrder: sortOrder
        )

        if let cache, cache.key == key { return cache.snapshot }

        let allEntries = log.entries
        let filteredEntries = allEntries
            .filter { directionFilter.matches($0.direction) && $0.matches(lowercasedQuery: query) }
            .sorted(using: sortOrder)

        let snapshot = Snapshot(
            allEntries: allEntries,
            filteredEntries: filteredEntries,
            query: query,
            isFiltered: directionFilter != .all || !query.isEmpty
        )
        cache = (key, snapshot)
        return snapshot
    }

    /// An entry's arguments with any JSON reply indented for reading.
    func formattedArguments(of entry: OSCEvent) -> String {
        if let inspectedArguments, inspectedArguments.id == entry.id {
            return inspectedArguments.text
        }
        let text = Self.prettyPrinted(entry.arguments)
        inspectedArguments = (entry.id, text)
        return text
    }

    private static func prettyPrinted(_ arguments: String) -> String {
        let body = arguments.count > 1
            && arguments.hasPrefix("\"") && arguments.hasSuffix("\"")
            ? String(arguments.dropFirst().dropLast())
            : arguments

        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let indented = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: indented, encoding: .utf8)
        else { return arguments }

        return text
    }
}

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var presenter = ActivityLogPresenter()
    @State private var selection: Set<OSCEvent.ID> = []
    @State private var isShowingInspector = false

    private func inspectedEntry(in entries: [OSCEvent]) -> OSCEvent? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    var body: some View {
#if os(iOS)
        // On iPad the log is presented in a sheet, which has no navigation
        // bar of its own for the toolbar and search field to live in.
        NavigationStack {
            activityContent
                .navigationTitle("Activity Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
#else
        activityContent
#endif
    }

    @ViewBuilder
    private var activityContent: some View {
        switch presenter.mode {
        case .messages:
            messageContent
        case .events:
            eventContent
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        let snapshot = presenter.snapshot(of: model.log)

        Group {
#if os(iOS)
        logList(snapshot)
#else
        Table(snapshot.filteredEntries, selection: $selection, sortOrder: $presenter.sortOrder) {
            TableColumn("") { entry in
                Image(systemName: entry.direction.systemImage)
                    .foregroundStyle(entry.direction.tint)
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Arguments", value: \.arguments) { entry in
                Text(entry.arguments)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
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
        .contextMenu(forSelectionType: OSCEvent.ID.self) { ids in
            if ids.count == 1 {
                Button("Show Message") { isShowingInspector = true }
            }
            Button(ids.count > 1 ? "Copy \(ids.count) Messages" : "Copy Message") {
                copy(ids, in: snapshot.filteredEntries)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            guard ids.count == 1 else { return }
            isShowingInspector = true
        }
#endif
        }
        .overlay { emptyState(for: snapshot) }
#if os(iOS)
        // A fixed-width segmented control can't overflow, so in the narrow
        // iPad sheet it collided with the bar's buttons. It gets its own
        // strip under the navigation bar instead.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                modePicker
                directionPicker
            }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
#endif
        .copyable(copyableLines(for: selection, in: snapshot.filteredEntries))
        .inspector(isPresented: $isShowingInspector) {
            messageInspector(for: snapshot)
        }
        .searchable(text: $presenter.searchText, prompt: "Filter by address or arguments")
        .safeAreaInset(edge: .bottom) {
            statusBar(for: snapshot)
        }
        .toolbar {
#if os(macOS)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                    modePicker
                    directionPicker
                }
            }
            // The filter stays in the bar; the actions below give way to the
            // overflow menu first when the bar runs out of room.
            .visibilityPriority(.high)
#endif

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
            .visibilityPriority(.low)

            ToolbarItem {
                Button {
                    model.log.clear()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(snapshot.allEntries.isEmpty)
                .help("Discard the recorded rows. Counters are unaffected.")
            }
            .visibilityPriority(.low)

            ToolbarItem {
                Toggle(isOn: $isShowingInspector) {
                    Label("Message", systemImage: "sidebar.right")
                }
                .help("Show the selected message in full")
            }
            .visibilityPriority(.low)
        }
    }

    private var eventContent: some View {
        let history = model.client.eventHistory
        let events = history.recentEvents.reversed()

        return List {
            if history.isIncomplete || model.isDataStale {
                Label("Activity incomplete", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: event.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.kind.rawValue).font(.headline)
                        if let detail = event.detail ?? (event.cueLabel.isEmpty ? nil : event.cueLabel) {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let workspaceName = event.workspaceName {
                            Text(workspaceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(event.timestamp, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                        Text(event.timestamp, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
        }
        .overlay {
            if history.recentEvents.isEmpty {
                ContentUnavailableView("No Events", systemImage: "clock.arrow.circlepath")
            }
        }
#if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            modePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
#else
        .toolbar {
            ToolbarItem(placement: .principal) {
                modePicker
            }
        }
#endif
    }

    private var modePicker: some View {
        Picker("Show", selection: $presenter.mode) {
            ForEach(ActivityLogPresenter.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func symbol(for kind: EventHistory.Event.Kind) -> String {
        switch kind {
        case .go: "play.fill"
        case .start: "play.circle"
        case .stop: "stop.fill"
        case .panic: "exclamationmark.octagon"
        case .connecting: "network"
        case .connected: "checkmark.circle"
        case .disconnected: "circle.slash"
        case .connectionLost, .connectionFailed: "exclamationmark.triangle"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .workspaceClosed: "rectangle.badge.xmark"
        case .passcodeRequired, .passcodeRejected: "lock"
        case .missedEvents: "clock.badge.exclamationmark"
        }
    }

    private var directionPicker: some View {
        Picker("Show", selection: $presenter.directionFilter) {
            ForEach(ActivityLogPresenter.DirectionFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

#if os(iOS)
    private func logList(_ snapshot: ActivityLogPresenter.Snapshot) -> some View {
        // Rows are plain buttons rather than List selection: a selection-driven
        // primary action only fires when the selection changes, so tapping
        // again after dismissing the inspector did nothing. Text selection is
        // left to the inspector, since it swallows the long press that would
        // otherwise open the context menu.
        List(snapshot.filteredEntries) { entry in
            Button {
                showMessage(entry)
            } label: {
                logRow(entry)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Show Message", systemImage: "text.viewfinder") {
                    showMessage(entry)
                }
                Button("Copy Message", systemImage: "doc.on.doc") {
                    copy([entry.id], in: snapshot.filteredEntries)
                }
            }
        }
        .listStyle(.plain)
    }

    private func showMessage(_ entry: OSCEvent) {
        selection = [entry.id]
        isShowingInspector = true
    }

    private func logRow(_ entry: OSCEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: entry.direction.systemImage)
                    .foregroundStyle(entry.direction.tint)
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(entry.byteCount, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(entry.address)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !entry.arguments.isEmpty {
                Text(entry.arguments)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
#endif

    @ViewBuilder
    private func emptyState(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        if snapshot.allEntries.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "list.bullet.rectangle",
                description: Text("OSC messages appear here.")
            )
        } else if snapshot.filteredEntries.isEmpty {
            if snapshot.query.isEmpty {
                ContentUnavailableView(
                    "No \(presenter.directionFilter.title) Messages",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("Nothing in the log matches this filter.")
                )
            } else {
                ContentUnavailableView.search(text: presenter.searchText)
            }
        }
    }

    private func statusBar(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        HStack(spacing: 16) {
            total(model.log.totalSent, direction: .outbound)
            total(model.log.totalReceived, direction: .inbound)
            if model.log.totalMalformed > 0 {
                total(model.log.totalMalformed, direction: .malformed)
            }

            Spacer()

            if snapshot.isFiltered {
                Text("\(snapshot.filteredEntries.count) of \(snapshot.allEntries.count) shown")
                    .foregroundStyle(.secondary)
            }

            if model.log.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .monospacedDigit()
#if os(iOS)
        // Clear the iPad window's larger corner radius.
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
#else
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
#endif
        .background(.bar)
    }

    private func total(_ count: Int, direction: OSCEvent.Direction) -> some View {
        Label {
            Text(count, format: .number)
        } icon: {
            Image(systemName: direction.systemImage)
                .foregroundStyle(direction.tint)
        }
        .help("\(direction.label) this session")
        .accessibilityLabel("\(count) \(direction.label.lowercased())")
    }

    @ViewBuilder
    private func messageInspector(for snapshot: ActivityLogPresenter.Snapshot) -> some View {
        let inspectedEntry = inspectedEntry(in: snapshot.allEntries)

        Group {
            if let entry = inspectedEntry {
                Form {
                    Section {
                        LabeledContent("Direction") {
                            Label(entry.direction.label, systemImage: entry.direction.systemImage)
                                .foregroundStyle(entry.direction.tint)
                        }
                        LabeledContent("Time") {
                            Text(entry.timestamp, format: .dateTime
                                .hour().minute().second().secondFraction(.fractional(3)))
                                .monospacedDigit()
                        }
                        LabeledContent("Size") {
                            Text("\(entry.byteCount.formatted()) bytes")
                                .monospacedDigit()
                        }
                    }

                    Section("Address") {
                        Text(entry.address)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !entry.arguments.isEmpty {
                        Section("Arguments") {
                            Text(presenter.formattedArguments(of: entry))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "text.viewfinder",
                    description: Text(selection.count > 1
                        ? "Select a row to see it in full."
                        : "Select a row to see its address and arguments in full.")
                )
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 340, max: 640)
    }

    private func copyableLines(
        for ids: Set<OSCEvent.ID>, in entries: [OSCEvent]
    ) -> [String] {
        entries
            .filter { ids.contains($0.id) }
            .map(\.copyableDescription)
    }

    private func copy(_ ids: Set<OSCEvent.ID>, in entries: [OSCEvent]) {
        let lines = copyableLines(for: ids, in: entries)
        guard !lines.isEmpty else { return }

        Pasteboard.copy(lines.joined(separator: "\n"))
    }
}

#Preview {
    ActivityLogView()
        .environment(AppModel.preview)
        .frame(width: 780, height: 460)
}
