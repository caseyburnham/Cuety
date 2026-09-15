import SwiftUI

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var directionFilter: DirectionFilter = .all
    @State private var selection: Set<OSCEvent.ID> = []
    @State private var isShowingInspector = false
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

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var isFiltered: Bool {
        directionFilter != .all || !query.isEmpty
    }

    private var filteredEntries: [OSCEvent] {
        model.log.entries
            .filter { entry in
                guard directionFilter.matches(entry.direction) else { return false }
                guard !query.isEmpty else { return true }
                return entry.address.lowercased().contains(query)
                    || entry.arguments.lowercased().contains(query)
            }
            .sorted(using: sortOrder)
    }

    private var inspectedEntry: OSCEvent? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.log.entries.first { $0.id == id }
    }

    var body: some View {
        Table(filteredEntries, selection: $selection, sortOrder: $sortOrder) {
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
        .overlay { emptyState }
        .copyable(filteredEntries.filter { selection.contains($0.id) }.map(\.copyableDescription))
        .contextMenu(forSelectionType: OSCEvent.ID.self) { ids in
            if ids.count == 1 {
                Button("Show Message") { isShowingInspector = true }
            }
            Button(ids.count > 1 ? "Copy \(ids.count) Messages" : "Copy Message") {
                copy(ids)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            guard ids.count == 1 else { return }
            isShowingInspector = true
        }
        .inspector(isPresented: $isShowingInspector) {
            messageInspector
        }
        .searchable(text: $searchText, prompt: "Filter by address or arguments")
        .safeAreaInset(edge: .bottom) {
            statusBar
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
                    model.log.clear()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.log.entries.isEmpty)
                .help("Discard the recorded rows. Counters are unaffected.")
            }

            ToolbarItem {
                Toggle(isOn: $isShowingInspector) {
                    Label("Message", systemImage: "sidebar.right")
                }
                .help("Show the selected message in full")
            }
        }
    }


    @ViewBuilder
    private var emptyState: some View {
        if model.log.entries.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "list.bullet.rectangle",
                description: Text("OSC messages appear here once you connect.")
            )
        } else if filteredEntries.isEmpty {
            if query.isEmpty {
                ContentUnavailableView(
                    "No \(directionFilter.title) Messages",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("Nothing in the log matches this filter.")
                )
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }


    private var statusBar: some View {
        HStack(spacing: 16) {
            total(model.log.totalSent, direction: .outbound)
            total(model.log.totalReceived, direction: .inbound)
            if model.log.totalMalformed > 0 {
                total(model.log.totalMalformed, direction: .malformed)
            }

            Spacer()

            if isFiltered {
                Text("\(filteredEntries.count) of \(model.log.entries.count) shown")
                    .foregroundStyle(.secondary)
            }

            if model.log.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
    private var messageInspector: some View {
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
                            Text(prettyPrinted(entry.arguments))
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
                        ? "Select a single row to see it in full."
                        : "Select a row to see its address and arguments in full.")
                )
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 340, max: 640)
    }

    private func prettyPrinted(_ arguments: String) -> String {
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

    private func copy(_ ids: Set<OSCEvent.ID>) {
        let lines = filteredEntries
            .filter { ids.contains($0.id) }
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
