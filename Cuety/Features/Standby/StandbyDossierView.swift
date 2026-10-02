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
                    description: Text("Waiting for Cuety to confirm the current cue with QLab.")
                )
            } else if let cue = model.standbyCue {
                dossier(cue)
            } else {
                emptyState
            }
        }
        .navigationTitle("Standby Dossier")
    }

    private func dossier(_ cue: Cue) -> some View {
        Form {
            Section("Standing By") {
                if let number = cue.displayNumber {
                    LabeledContent("Cue", value: number)
                }
                LabeledContent("Name", value: cue.displayName ?? "Untitled")
                LabeledContent("Workspace", value: client.workspace?.displayName ?? "Unknown")
                LabeledContent("Cue List", value: client.watchedCueList?.displayName ?? "Unknown")
                LabeledContent("Type", value: cue.type ?? "Unknown")
                LabeledContent("Color") {
                    HStack {
                        if let color = cue.color {
                            Circle().fill(color).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text(cue.colorName ?? "Unknown")
                    }
                }
                LabeledContent("Cue ID", value: cue.uniqueID)
                    .fontDesign(.monospaced)
            }

            Section("Readiness") {
                LabeledContent("Armed", value: state(cue.isArmed, yes: "Armed", no: "Disarmed"))
                LabeledContent("Loaded", value: state(cue.isLoaded, yes: "Loaded", no: "Not Loaded"))
                LabeledContent("Broken") {
                    Text(state(cue.isBroken, yes: "Broken", no: "Not Broken"))
                        .foregroundStyle(cue.isBroken == true ? Color.red : Color.primary)
                }
                LabeledContent("Flagged", value: state(cue.isFlagged, yes: "Flagged", no: "Not Flagged"))
            }

            Section("Timing") {
                LabeledContent("Duration", value: duration(cue.duration))
                LabeledContent("Pre-Wait", value: duration(cue.preWait))
                LabeledContent("Post-Wait", value: duration(cue.postWait))
                LabeledContent("Continue", value: cue.continueMode?.title ?? "Unknown")
            }

            Section("Notes") {
                Text(cue.notes.map { $0.isEmpty ? "No notes" : $0 } ?? "Notes not received yet")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let group = client.watchedGraph?.containingRow(of: cue.uniqueID) {
                Section("Containing Group") {
                    Text(cueLabel(group))
                }
            }

            if cue.isGroup {
                Section("Group Contents") {
                    if cue.children.isEmpty {
                        Text("No child cues in the current cue tree")
                            .foregroundStyle(.secondary)
                    } else {
                        OutlineGroup(cue.children, children: \.dossierChildren) { child in
                            HStack {
                                Text(cueLabel(child))
                                Spacer()
                                Text(child.type ?? "Unknown")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
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
