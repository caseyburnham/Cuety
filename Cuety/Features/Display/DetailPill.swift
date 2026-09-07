import SwiftUI

/// One piece of cue metadata, rendered as a Liquid Glass capsule.
///
/// Every pill kind decides for itself whether it has anything to say about a
/// given cue. That is the central idea of the row: the *presence* of a pill is
/// information. A cue with no pre-wait shows no pre-wait pill rather than
/// "0.0s", so a glance at the row tells the operator what is unusual about this
/// cue rather than making them read values.
struct DetailPill: View {
    let kind: DetailPillKind
    let cue: Cue

    var body: some View {
        if let content = Self.content(for: kind, cue: cue) {
            Label {
                Text(content.text)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: content.isFlexible ? 240 : nil, alignment: .leading)
            } icon: {
                Image(systemName: content.systemImage)
                    .foregroundStyle(content.tint ?? .secondary)
            }
            .font(.callout)
            .labelStyle(.titleAndIcon)
            // A pill with bounded text holds its natural width; only free text
            // is allowed to give way, and it yields first, so a long note
            // truncates instead of squeezing "Disarmed" down to "Disar…".
            .fixedSize(horizontal: !content.isFlexible, vertical: false)
            .layoutPriority(content.isFlexible ? -1 : 0)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(
                content.tint.map { Glass.regular.tint($0.opacity(0.28)) } ?? .regular,
                in: .capsule
            )
            .help(content.help)
            .accessibilityLabel("\(kind.title): \(content.text)")
        }
    }

    /// What a pill shows, or `nil` when it has nothing to say.
    struct Content {
        let text: String
        let systemImage: String
        var tint: Color?
        var help: String
        /// Whether the text is free-form and may be shortened to fit. True only
        /// for notes; every other pill's text is a short bounded value that
        /// should never be truncated.
        var isFlexible = false
    }

    static func content(for kind: DetailPillKind, cue: Cue) -> Content? {
        switch kind {
        case .cueType:
            guard let type = cue.type, !type.isEmpty else { return nil }
            return Content(
                text: type,
                systemImage: systemImage(forCueType: type),
                help: "Cue type"
            )

        case .duration:
            guard let duration = cue.duration, duration > 0 else { return nil }
            return Content(
                text: formatDuration(duration),
                systemImage: "clock",
                help: "Duration"
            )

        case .preWait:
            // Only interesting when non-zero: a pre-wait of zero is the norm.
            guard let preWait = cue.preWait, preWait > 0 else { return nil }
            return Content(
                text: formatDuration(preWait),
                systemImage: "hourglass.tophalf.filled",
                tint: .orange,
                help: "Pre-wait before this cue acts"
            )

        case .postWait:
            guard let postWait = cue.postWait, postWait > 0 else { return nil }
            return Content(
                text: formatDuration(postWait),
                systemImage: "hourglass.bottomhalf.filled",
                tint: .orange,
                help: "Post-wait before the next cue"
            )

        case .continueMode:
            // "Do not continue" is the default, so showing it would be noise.
            guard let mode = cue.continueMode, mode != .doNotContinue else { return nil }
            return Content(
                text: mode.title,
                systemImage: "arrow.down",
                tint: .blue,
                help: "This cue continues automatically"
            )

        case .cueList:
            guard let listName = cue.listName, !listName.isEmpty else { return nil }
            return Content(
                text: listName,
                systemImage: "list.bullet",
                help: "Cue list"
            )

        case .armed:
            // Inverted deliberately: armed is normal, disarmed is the warning.
            guard cue.isArmed == false else { return nil }
            return Content(
                text: "Disarmed",
                systemImage: "power",
                tint: .red,
                help: "This cue is disarmed and will not fire"
            )

        case .flagged:
            guard cue.isFlagged == true else { return nil }
            return Content(
                text: "Flagged",
                systemImage: "flag.fill",
                tint: .yellow,
                help: "This cue is flagged in QLab"
            )

        case .notes:
            guard let notes = cue.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !notes.isEmpty
            else { return nil }
            return Content(
                text: notes,
                systemImage: "ellipsis.bubble",
                help: notes,
                isFlexible: true
            )
        }
    }

    /// Maps QLab's cue type strings onto SF Symbols.
    static func systemImage(forCueType type: String) -> String {
        switch type.lowercased() {
        case "audio": "speaker.wave.2"
        case "mic": "mic"
        case "video": "film"
        case "camera": "video"
        case "titles": "film"
        case "light": "lightbulb"
        case "group": "square.stack.3d.up"
        case "fade": "slider.horizontal.below.rectangle"
        case "wait": "hourglass"
        case "start", "go": "play.circle"
        case "stop", "hard stop": "stop.circle"
        case "pause": "pause.circle"
        case "load": "progress.indicator"
        case "reset": "backward.end"
        case "goto": "arrow.right"
        case "target": "arrow.down.forward.circle"
        case "arm", "disarm": "power"
        case "memo": "ellipsis.bubble"
        case "script": "applescript"
        case "network": "network"
        case "midi": "ev.plug.ac.type.2"
        case "midi file": "music.note"
        case "timecode": "clock"
        case "osc": "network"
        case "devamp": "arrow.uturn.right"
        default: "square.stack.3d.up"
        }
    }

    /// Cue times read best as seconds under a minute, and mm:ss above it.
    static func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return interval.formatted(.number.precision(.fractionLength(interval < 10 ? 1 : 0))) + "s"
        }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// The row of pills beneath the cue name.
///
/// One `GlassEffectContainer` for the whole row, per Apple's guidance to group
/// glass effects: it lets neighbouring pills blend and morph into one another
/// as they appear and disappear on a cue change, and it renders in one pass
/// instead of one per pill.
struct DetailPillsRow: View {
    let cue: Cue
    let kinds: [DetailPillKind]

    @Namespace private var glassNamespace

    /// Only the pills that actually have something to show for this cue.
    private var populated: [DetailPillKind] {
        kinds.filter { DetailPill.content(for: $0, cue: cue) != nil }
    }

    var body: some View {
        if !populated.isEmpty {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(populated) { kind in
                        DetailPill(kind: kind, cue: cue)
                            .glassEffectID(kind, in: glassNamespace)
                            .glassEffectTransition(.matchedGeometry)
                    }
                }
            }
            .animation(Motion.pill, value: populated)
            .animation(Motion.pill, value: cue.uniqueID)
        }
    }
}

#Preview {
    var cue = Cue(uniqueID: "c")
    cue.number = "12.5"
    cue.name = "Thunder Crash"
    cue.type = "Audio"
    cue.listName = "Main Cue List"
    cue.duration = 4.25
    cue.preWait = 1.5
    cue.continueMode = .autoContinue
    cue.isFlagged = true
    cue.isArmed = false
    cue.notes = "Cue the rain"

    return DetailPillsRow(cue: cue, kinds: DetailPillKind.defaultOrder)
        .padding(40)
        .frame(width: 900)
}
