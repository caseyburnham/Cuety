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
                    .frame(
                        maxWidth: content.isFlexible ? Self.flexibleTextMaxWidth : nil,
                        alignment: .leading
                    )
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
            // The border goes on *before* the glass, not after. Glass renders
            // its material behind the view it's applied to and composites over
            // anything layered on afterwards, which mutes a trailing overlay to
            // a dark smudge — the same reason the tinted icon above stays crisp
            // and a stroke added below the glass line does not.
            .overlay {
                if content.isOutlined, let tint = content.tint {
                    Capsule().strokeBorder(tint, lineWidth: 1.5)
                }
            }
            .glassEffect(Self.glass(for: content), in: .capsule)
            .help(content.help)
            .accessibilityLabel("\(kind.title): \(content.text)")
        }
    }

    /// How wide free-form text is allowed to run before it truncates. Generous,
    /// because the only flexible pill now has a line to itself.
    static let flexibleTextMaxWidth: CGFloat = 520

    /// An outlined pill states itself with its border, so it keeps clear glass:
    /// a tinted fill *and* a stroke would be the same fact told twice, and the
    /// two together read as a much louder pill than any value warrants.
    private static func glass(for content: Content) -> Glass {
        guard !content.isOutlined, let tint = content.tint else { return .regular }
        return Glass.regular.tint(tint.opacity(0.28))
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
        /// Draws the tint as a border around clear glass rather than as a fill.
        ///
        /// Reserved for a cue that is a different *kind* of thing rather than
        /// one carrying a notable value — currently only a group. A filled pill
        /// says "look at this value"; an outlined one says "this cue is built
        /// differently", which is a distinction worth being able to make.
        var isOutlined = false
    }

    static func content(for kind: DetailPillKind, cue: Cue) -> Content? {
        switch kind {
        case .cueType:
            guard let type = cue.type, !type.isEmpty else { return nil }
            // The one kind whose glyph depends on the value rather than the
            // kind, because "which sort of cue is this" is the whole point.
            //
            // A group is called out because it is structurally unlike every
            // other cue: firing it fires the cues inside it, so what happens
            // on the next GO isn't described by this row alone.
            return Content(
                text: type,
                systemImage: systemImage(forCueType: type),
                tint: cue.isGroup ? .green : nil,
                help: cue.isGroup
                    ? "Group cue — firing it fires the cues inside it"
                    : "Cue type",
                isOutlined: cue.isGroup
            )

        case .duration:
            guard let duration = cue.duration, duration > 0 else { return nil }
            return Content(
                text: formatDuration(duration),
                systemImage: kind.systemImage,
                help: "Duration"
            )

        case .preWait:
            // Only interesting when non-zero: a pre-wait of zero is the norm.
            guard let preWait = cue.preWait, preWait > 0 else { return nil }
            return Content(
                text: formatDuration(preWait),
                systemImage: kind.systemImage,
                tint: .orange,
                help: "Pre-wait before this cue acts"
            )

        case .postWait:
            guard let postWait = cue.postWait, postWait > 0 else { return nil }
            return Content(
                text: formatDuration(postWait),
                systemImage: kind.systemImage,
                tint: .orange,
                help: "Post-wait before the next cue"
            )

        case .continueMode:
            // "Do not continue" is the default, so showing it would be noise.
            guard let mode = cue.continueMode, mode != .doNotContinue else { return nil }
            // The mode's own glyph, so this pill and the drawer's indicator
            // draw the same thing for the same cue.
            return Content(
                text: mode.title,
                systemImage: mode.systemImage,
                tint: .blue,
                help: "This cue continues automatically"
            )

        case .cueList:
            guard let listName = cue.listName, !listName.isEmpty else { return nil }
            return Content(
                text: listName,
                systemImage: kind.systemImage,
                help: "Cue list"
            )

        case .armed:
            // Inverted deliberately: armed is normal, disarmed is the warning.
            guard cue.isArmed == false else { return nil }
            return Content(
                text: "Disarmed",
                systemImage: kind.systemImage,
                tint: .red,
                help: "This cue is disarmed and will not fire"
            )

        case .flagged:
            guard cue.isFlagged == true else { return nil }
            return Content(
                text: "Flagged",
                systemImage: kind.systemImage,
                tint: .yellow,
                help: "This cue is flagged in QLab"
            )

        case .notes:
            guard let notes = cue.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !notes.isEmpty
            else { return nil }
            return Content(
                text: notes,
                systemImage: kind.systemImage,
                help: notes,
                isFlexible: true
            )
        }
    }

    /// Maps QLab's cue type strings onto SF Symbols.
    ///
    /// The default is deliberately a question mark rather than a plausible
    /// glyph: a cue type Cuety doesn't recognise should say so, not quietly
    /// present itself as a group.
    static func systemImage(forCueType type: String) -> String {
        switch type.lowercased() {
        case "audio": "speaker.wave.2"
        case "mic": "mic"
        case "video": "film"
        case "camera": "video"
        case "titles", "text": "textformat"
        case "light": "lightbulb"
        case "group": "square.stack.3d.up"
        case "fade": "slider.horizontal.below.rectangle"
        case "wait": "hourglass"
        case "start", "go": "play.circle"
        case "stop", "hard stop": "stop.circle"
        case "pause": "pause.circle"
        case "load": "tray.and.arrow.down"
        case "reset": "backward.end"
        case "goto": "arrow.right"
        case "target": "scope"
        case "arm", "disarm": "power"
        case "memo": "ellipsis.bubble"
        case "script": "applescript"
        case "network", "osc": "network"
        case "midi": "pianokeys"
        case "midi file": "music.note"
        case "timecode": "clock"
        case "devamp": "arrow.uturn.right"
        default: "questionmark.square.dashed"
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

/// The pills beneath the cue name: the short values on one line, and the note
/// on a line of its own beneath them.
///
/// Notes are split out because they are a different shape of information. Every
/// other pill is a glanceable token a few characters wide, and the row is meant
/// to be read sideways in one pass; a sentence of free text sitting among them
/// dominates the line and pushes the tokens off to one side. Given its own
/// line, the note can run wide without disturbing the reading order above it.
///
/// One `GlassEffectContainer` for both lines, per Apple's guidance to group
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

    /// The short values, in the operator's order.
    private var inlineKinds: [DetailPillKind] {
        populated.filter { $0 != .notes }
    }

    /// Present only when notes are both enabled and non-empty. Its position in
    /// `pillOrder` no longer affects anything, which is the one thing the
    /// operator gives up by having it on its own line.
    private var noteKind: DetailPillKind? {
        populated.contains(.notes) ? .notes : nil
    }

    var body: some View {
        if !populated.isEmpty {
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 10) {
                    if !inlineKinds.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(inlineKinds) { kind in
                                pill(kind)
                            }
                        }
                    }

                    if let noteKind {
                        pill(noteKind)
                    }
                }
            }
            .animation(Motion.pill, value: populated)
            .animation(Motion.pill, value: cue.uniqueID)
        }
    }

    private func pill(_ kind: DetailPillKind) -> some View {
        DetailPill(kind: kind, cue: cue)
            .glassEffectID(kind, in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
    }
}

#Preview("Action cue") {
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
    cue.notes = "Hold for the door slam, then go on the lighting cue"

    return DetailPillsRow(cue: cue, kinds: DetailPillKind.defaultOrder)
        .padding(40)
        .frame(width: 900)
}

/// The outlined group pill, and the note wide on its own line.
#Preview("Group cue") {
    var child = Cue(uniqueID: "child")
    child.number = "13.1"

    var cue = Cue(uniqueID: "g")
    cue.number = "13"
    cue.name = "Act Two Preset"
    cue.type = "Group"
    cue.listName = "Main Cue List"
    cue.children = [child]
    cue.notes = "Fires the whole preset — check the deck is clear before this one"

    return DetailPillsRow(cue: cue, kinds: DetailPillKind.defaultOrder)
        .padding(40)
        .frame(width: 900)
}
