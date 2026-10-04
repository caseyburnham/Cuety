import SwiftUI

struct StandbyDossierView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        Group {
            if model.isDataStale {
                ContentUnavailableView(
                    "Data May Be Stale",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text("Confirming the standby cue with QLab.")
                )
            } else if let cue = model.standbyCue {
                dossier(cue)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dossier(_ cue: Cue) -> some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: DetailPill.systemImage(forCueType: cue.type ?? ""))
                        .rotationEffect(DetailPill.glyphRotation(forCueType: cue.type ?? ""))
                        .font(.largeTitle)
                        .foregroundStyle(cue.color ?? .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        if let number = cue.displayNumber {
                            Text(number)
                                .font(.largeTitle.bold())
                                .monospacedDigit()
                                .accessibilityLabel("Cue \(number)")
                        }
                        Text(cue.displayName ?? "Untitled")
                            .font(.headline)
                    }
                }
            } header: {
                Label("Standing By", systemImage: "info.circle.text.page")
            }

            Section {
                if let number = cue.displayNumber {
                    field("Cue", value: number)
                }
                field("Name", value: cue.displayName ?? "Untitled")
                field("Workspace", value: client.workspace?.displayName ?? "Unknown")
                field("Cue List", value: client.watchedCueList?.displayName ?? "Unknown")
                field("Type", value: cue.type ?? "Unknown")
                LabeledContent("Color") {
                    HStack {
                        if let color = cue.color {
                            Circle().fill(color).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text(cue.colorName?.capitalized ?? "Unknown")
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Cue ID") {
                    Text(cue.uniqueID)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            } header: {
                Label("Identity", systemImage: "tag")
            }

            Section {
                field("Armed", value: state(cue.isArmed, yes: "Armed", no: "Disarmed"))
                field("Loaded", value: state(cue.isLoaded, yes: "Loaded", no: "Not Loaded"))
                LabeledContent("Broken") {
                    Text(state(cue.isBroken, yes: "Broken", no: "Not Broken"))
                        .foregroundStyle(cue.isBroken == true ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
                field("Flagged", value: state(cue.isFlagged, yes: "Flagged", no: "Not Flagged"))
            } header: {
                Label("Readiness", systemImage: "checkmark.shield")
            }

            Section {
                field("Duration", value: duration(cue.duration))
                field("Pre-Wait", value: duration(cue.preWait))
                field("Post-Wait", value: duration(cue.postWait))
                LabeledContent("Continue") {
                    Label(cue.continueMode?.title ?? "Unknown",
                          systemImage: cue.continueMode?.systemImage ?? "questionmark.circle")
                        .textSelection(.enabled)
                }
            } header: {
                Label("Timing", systemImage: "clock")
            }

            Section {
                Text(cue.notes.map { $0.isEmpty ? "No notes" : $0 } ?? "Unknown")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } header: {
                Label("Notes", systemImage: "note.text")
            }

            if let group = client.watchedGraph?.containingRow(of: cue.uniqueID) {
                Section {
                    Text(cueLabel(group))
                        .textSelection(.enabled)
                } header: {
                    Label("Containing Group", systemImage: "folder")
                }
            }

            if cue.isGroup {
                Section {
                    if cue.children.isEmpty {
                        Text("No child cues")
                            .foregroundStyle(.secondary)
                    } else {
                        OutlineGroup(cue.children, children: \.dossierChildren) { child in
                            HStack {
                                Label {
                                    Text(cueLabel(child))
                                } icon: {
                                    Image(systemName: DetailPill.systemImage(forCueType: child.type ?? ""))
                                        .rotationEffect(DetailPill.glyphRotation(forCueType: child.type ?? ""))
                                }
                                Spacer()
                                Text(child.type ?? "Unknown")
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    Label("Group Contents", systemImage: "list.bullet.indent")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value).textSelection(.enabled)
        }
    }

    private func state(_ value: Bool?, yes: String, no: String) -> String {
        value.map { $0 ? yes : no } ?? "Unknown"
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unknown" }
        return value.cueDurationText
    }

    private func cueLabel(_ cue: Cue) -> String {
        let label = [cue.displayNumber, cue.displayName].compactMap { $0 }.joined(separator: " · ")
        return label.isEmpty ? "Untitled Cue" : label
    }

    @ViewBuilder
    private var emptyState: some View {
        if !client.status.hasLiveData {
            ContentUnavailableView(client.status.title, systemImage: client.status.systemImage,
                                   description: Text(client.status.detail))
        } else if client.cueLists.isEmpty {
            ContentUnavailableView("No Cue Lists", systemImage: "list.bullet.rectangle",
                                   description: Text("This workspace has no cue lists."))
        } else if client.watchedCueListID == nil {
            ContentUnavailableView("No Cue List Selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose a cue list in the sidebar."))
        } else if client.isWatchingCueCart {
            ContentUnavailableView("Cue Cart", systemImage: "square.grid.3x3",
                                   description: Text("Cue carts have no playhead. Choose a cue list in the sidebar."))
        } else if case .unknown(let reason) = client.watchedPlayhead {
            ContentUnavailableView("Playhead Unknown", systemImage: "questionmark.circle",
                                   description: Text(reason))
        } else if client.watchedPlayhead == nil {
            ContentUnavailableView("Waiting for QLab", systemImage: "progress.indicator",
                                   description: Text("Playhead details not received yet."))
        } else if client.currentPlayheadCueID != nil {
            ContentUnavailableView("Standby Cue Unavailable", systemImage: "questionmark.circle",
                                   description: Text("The playhead cue is not in the current cue tree."))
        } else {
            ContentUnavailableView("No Cue Standing By", systemImage: "arrowtriangle.right",
                                   description: Text("The playhead in this cue list is not set."))
        }
    }
}

private extension Cue {
    var dossierChildren: [Cue]? { children.isEmpty ? nil : children }
}
