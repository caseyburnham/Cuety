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

    /// The name of the cue list this cue belongs to, which has to be supplied
    /// because the cue itself does not carry it — see
    /// ``Swift/Array/cueList(containing:)``.
    let cueListName: String?

    /// How large the pill is set, from ``Preferences/pillSize``.
    var size: PillSize = .medium

    /// Whether the cue-type pill spells out the type beside its glyph, from
    /// ``Preferences/showsCueTypeLabel``. With it off the pill keeps the glyph
    /// alone, which is the one pill whose symbol already names its value.
    var showsCueTypeLabel = true

    var body: some View {
        if let content = Self.content(for: kind, cue: cue, cueListName: cueListName) {
            if content.isFlexible {
                // Two candidates: one sized to its own text, one that gives
                // way. `ViewThatFits` takes the first whose ideal size fits
                // and the last when none do, which is exactly the rule wanted
                // here — hug the text, unless hugging it would not fit.
                //
                // Without this the note pill was a 520pt capsule whatever it
                // held, because `frame(maxWidth:)` takes the width it is
                // *proposed* rather than the width its text needs. A ten-word
                // note sat in the middle of a fixed slab with an inch of glass
                // either side of it.
                ViewThatFits(in: .horizontal) {
                    capsule(for: content, hugsText: true)
                    capsule(for: content, hugsText: false)
                }
            } else {
                capsule(for: content, hugsText: false)
            }
        }
    }

    private func capsule(for content: Content, hugsText: Bool) -> some View {
        label(for: content)
            .font(size.font)
            // A pill with bounded text holds its natural width; only free text
            // is allowed to give way, and it yields first, so a long note
            // truncates instead of squeezing "Disarmed" down to "Disar…".
            //
            // Fixing the size horizontally is also what makes the hugging
            // candidate hug: it proposes nothing to the text, so the width cap
            // above clamps the text's own ideal width instead of filling a
            // proposal.
            .fixedSize(horizontal: hugsText || !content.isFlexible, vertical: false)
            .layoutPriority(content.isFlexible ? -1 : 0)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(Self.glass(for: content), in: .capsule)
            .help(content.help)
            .accessibilityLabel("\(kind.title): \(content.text)")
    }

    /// The pill's glyph and text, in whichever combination this pill uses.
    ///
    /// Three label styles rather than three hand-built stacks: a `Label` that
    /// always carries both pieces and a style that decides which to draw keeps
    /// the accessibility label and the help text identical in all three cases.
    @ViewBuilder
    private func label(for content: Content) -> some View {
        let label = Label {
            Text(content.text)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(content.isCentred ? .center : .leading)
                .frame(
                    maxWidth: content.isFlexible ? Self.flexibleTextMaxWidth : nil,
                    alignment: content.isCentred ? .center : .leading
                )
        } icon: {
            Image(systemName: content.systemImage)
                .rotationEffect(content.glyphRotation)
                .foregroundStyle(content.glyphTint ?? content.tint ?? .secondary)
        }

        if content.hidesGlyph {
            label.labelStyle(.titleOnly)
        } else if showsText(for: kind) {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    /// Only the cue-type pill can have its text switched off; every other
    /// pill's glyph names a category rather than the value beside it, so
    /// hiding the value would leave nothing behind.
    private func showsText(for kind: DetailPillKind) -> Bool {
        kind != .cueType || showsCueTypeLabel
    }

    /// How wide free-form text is allowed to run before it truncates. Generous,
    /// because the only flexible pill now has a line to itself.
    static let flexibleTextMaxWidth: CGFloat = 520

    /// A tinted pill is tinted glass, whatever the tint means.
    ///
    /// The group pill used to be an exception, drawn as a green stroke around
    /// clear glass. A `Capsule().strokeBorder` overlay is Cuety's own idea of
    /// an outlined capsule rather than anything the platform offers, and it had
    /// to be layered *under* the glass to survive compositing — so it is gone,
    /// and a group now reads as green the same way a pre-wait reads as orange.
    private static func glass(for content: Content) -> Glass {
        guard let tint = content.tint else { return .regular }
        return Glass.regular.tint(tint.opacity(0.28))
    }

    /// What a pill shows, or `nil` when it has nothing to say.
    struct Content {
        let text: String
        let systemImage: String
        /// Colours the glass *and* the glyph, for a pill that should read as
        /// coloured from across a booth.
        var tint: Color?
        /// Colours the glyph alone, leaving the glass clear.
        ///
        /// The quieter of the two, for a cue type worth telling apart at a
        /// glance without another filled pill competing with the values
        /// beside it. Overrides ``tint`` for the glyph when both are set.
        var glyphTint: Color?
        var help: String
        /// Whether the text is free-form and may be shortened to fit. True only
        /// for notes and cue-list names; every other pill's text is a short
        /// bounded value that should never be truncated.
        var isFlexible = false
        /// Turns the glyph, for a cue type whose symbol is the right shape the
        /// other way up — a Disarm cue being the upended Arm cue.
        var glyphRotation: Angle = .zero
        /// Drops the glyph entirely, leaving the text alone in the capsule.
        var hidesGlyph = false
        /// Centres the text rather than leaving it leading-aligned. Goes with
        /// ``hidesGlyph``: text with nothing beside it has no reason to sit off
        /// to one side of a centred display.
        var isCentred = false
    }

    static func content(
        for kind: DetailPillKind, cue: Cue, cueListName: String?
    ) -> Content? {
        switch kind {
        case .cueType:
            guard let type = cue.type, !type.isEmpty else { return nil }
            // The one kind whose glyph and colour depend on the value rather
            // than the kind, because "which sort of cue is this" is the whole
            // point.
            let colours = colours(forCueType: type, isGroup: cue.isGroup)
            return Content(
                text: type,
                systemImage: systemImage(forCueType: type),
                tint: colours.pill,
                glyphTint: colours.glyph,
                // Names the type rather than the pill. It used to read "Cue
                // type", which says nothing at all once the operator has
                // switched the label off and left the glyph to speak for
                // itself — the tooltip is then the only way to ask what an
                // unfamiliar symbol means.
                help: cue.isGroup
                    ? "Group cue — firing it fires the cues inside it"
                    : "\(type) cue",
                glyphRotation: glyphRotation(forCueType: type)
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
            // The containing list, worked out from the cue tree by the caller.
            // This used to read `cue.listName`, which is QLab's *displayed
            // name for the cue* — so a cue called "Thunder Crash" in the Main
            // Cue List reported its cue list as "Thunder Crash".
            guard let cueListName, !cueListName.isEmpty else { return nil }
            return Content(
                text: cueListName,
                systemImage: kind.systemImage,
                help: "Cue list",
                // Free-form text, like a note: an operator can call a cue list
                // anything, and "Act Two — Understudy Track (Revised)" is not
                // a short bounded value. Marked fixed-width, it was the pill
                // that shoved the whole row off the edge of a narrow window.
                isFlexible: true
            )

        case .armed:
            // Inverted deliberately: armed is normal, disarmed is the warning.
            guard cue.isArmed == false else { return nil }
            return Content(
                text: "Disarmed",
                systemImage: kind.systemImage,
                tint: .red,
                help: "This cue is disarmed and will not fire",
                glyphRotation: kind.glyphRotation
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
            // No glyph, and centred. A note already has a line to itself under
            // a centred display, so a speech bubble at its left edge only
            // announced what the sentence beside it makes obvious and pulled
            // the text off-centre doing it.
            return Content(
                text: notes,
                systemImage: kind.systemImage,
                help: notes,
                isFlexible: true,
                hidesGlyph: true,
                isCentred: true
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
        case "load": "circle.dashed"
        case "reset": "backward.end.circle"
        case "goto": "arrow.right"
        case "target": "arrow.down.right.circle"
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

    /// What colour a cue type carries, and how much of the pill it colours.
    ///
    /// Two strengths, because the cue types divide in two. A Start, Stop, or
    /// Pause takes hold of the show on the next GO, and a group fires
    /// everything inside it — those read as a whole tinted pill, the loudest
    /// thing the row can say. Load, Fade, Arm, and Disarm colour their glyph
    /// only: worth telling apart at a glance, but four more filled pills
    /// would drown out the durations and waits beside them.
    ///
    /// Most cue types are deliberately left uncoloured. Colour means
    /// something here, and a palette covering everything would mean nothing.
    static func colours(
        forCueType type: String, isGroup: Bool
    ) -> (pill: Color?, glyph: Color?) {
        // Checked ahead of the type string: a cue with children is a group
        // whatever QLab calls it — see ``Cue/isGroup``.
        if isGroup { return (.green, nil) }

        switch type.lowercased() {
        case "start", "go": return (.green, nil)
        case "stop", "hard stop": return (.red, nil)
        case "pause": return (.orange, nil)
        case "load", "fade": return (nil, .yellow)
        case "arm": return (nil, .green)
        case "disarm": return (nil, .red)
        default: return (nil, nil)
        }
    }

    /// How far to turn a cue type's glyph.
    ///
    /// Arm and Disarm are one pair of opposites sharing one symbol, and there
    /// is no `power` variant for the off case — so Disarm gets the same glyph
    /// inverted, which reads as the reverse of Arm rather than as a second cue
    /// type that happens to look identical.
    static func glyphRotation(forCueType type: String) -> Angle {
        type.lowercased() == "disarm" ? .degrees(180) : .zero
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

/// Lays views out in a row, wrapping onto further rows when they do not fit.
///
/// `Layout` is the system's extension point for arrangements SwiftUI has no
/// stock container for, and there is no wrapping stack — so this is not a
/// hand-rolled substitute for something the platform already does.
///
/// An `HStack` cannot fit an arbitrary number of pills into an arbitrary
/// width, and the pills deliberately refuse to shrink so that "Disarmed" never
/// becomes "Disar…". Reproduced at 260pt, the row ran off *both* edges of the
/// window with five of its seven pills not on screen at all — on a display
/// whose job is to be readable from across a booth, information vanishing
/// silently is the worst available outcome. Wrapping keeps every pill visible;
/// scrolling would hide them behind a gesture nobody is there to make, and
/// dropping them would lose the information without saying so.
struct WrappingPillLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let available = proposal.width ?? .infinity
        let rows = rows(for: subviews, availableWidth: available)

        let width = rows.map { row in
            row.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width }
                + spacing * CGFloat(max(0, row.count - 1))
        }.max() ?? 0

        let height = rows.reduce(0) { total, row in
            total + rowHeight(row, in: subviews)
        } + spacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: min(width, available), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = rows(for: subviews, availableWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            let rowWidth = row.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width }
                + spacing * CGFloat(max(0, row.count - 1))
            let height = rowHeight(row, in: subviews)
            // Centred, because the display centres everything else. A
            // left-aligned final row under a centred cue number reads as a
            // mistake.
            var x = bounds.minX + (bounds.width - rowWidth) / 2

            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }

            y += height + spacing
        }
    }

    /// Groups subviews into rows that fit. A subview wider than the whole
    /// container still gets a row of its own rather than being dropped.
    private func rows(for subviews: Subviews, availableWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0

        for index in subviews.indices {
            let width = subviews[index].sizeThatFits(.unspecified).width
            let needed = current.isEmpty ? width : width + spacing

            if !current.isEmpty, x + needed > availableWidth {
                rows.append(current)
                current = [index]
                x = width
            } else {
                current.append(index)
                x += needed
            }
        }

        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func rowHeight(_ row: [Int], in subviews: Subviews) -> CGFloat {
        row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
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
    /// The name of the cue list the cue belongs to, which only the caller can
    /// work out — see ``Swift/Array/cueList(containing:)``.
    let cueListName: String?

    /// How large the pills are set, from ``Preferences/pillSize``. The spacing
    /// between them scales with it, so a row of large pills is not a row of
    /// small gaps.
    var size: PillSize = .medium

    /// Whether the cue-type pill spells out the type, from
    /// ``Preferences/showsCueTypeLabel``.
    var showsCueTypeLabel = true

    @Namespace private var glassNamespace

    /// Only the pills that actually have something to show for this cue.
    private var populated: [DetailPillKind] {
        kinds.filter { DetailPill.content(for: $0, cue: cue, cueListName: cueListName) != nil }
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
            GlassEffectContainer(spacing: size.glassSpacing) {
                VStack(spacing: size.spacing) {
                    if !inlineKinds.isEmpty {
                        // Wrapping, not an `HStack`: see ``WrappingPillLayout``.
                        // At a narrow width an `HStack` put five of seven pills
                        // outside the window.
                        WrappingPillLayout(spacing: size.spacing) {
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
            .motion(Motion.pill, value: populated)
            .motion(Motion.pill, value: cue.uniqueID)
        }
    }

    private func pill(_ kind: DetailPillKind) -> some View {
        DetailPill(
            kind: kind,
            cue: cue,
            cueListName: cueListName,
            size: size,
            showsCueTypeLabel: showsCueTypeLabel
        )
        .glassEffectID(kind, in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
    }
}

// The previews set `listName` the way QLab actually does — to the cue's own
// displayed name — and pass the containing list separately. Setting it to
// "Main Cue List" was the same mistake the Cue List pill used to make, which
// meant the previews confirmed the bug instead of showing it.

#Preview("Action cue") {
    var cue = Cue(uniqueID: "c")
    cue.number = "12.5"
    cue.name = "Thunder Crash"
    cue.listName = "Thunder Crash"
    cue.type = "Audio"
    cue.duration = 4.25
    cue.preWait = 1.5
    cue.continueMode = .autoContinue
    cue.isFlagged = true
    cue.isArmed = false
    cue.notes = "Hold for the door slam, then go on the lighting cue"

    return DetailPillsRow(
        cue: cue, kinds: DetailPillKind.defaultOrder, cueListName: "Main Cue List"
    )
    .padding(40)
    .frame(width: 900)
}

/// The three pill sizes side by side, which is the only way to judge whether
/// Small is still readable and Large is not absurd.
#Preview("Pill sizes") {
    var cue = Cue(uniqueID: "s")
    cue.type = "Audio"
    cue.duration = 4.25
    cue.preWait = 1.5
    cue.continueMode = .autoFollow
    cue.isArmed = false

    return VStack(spacing: 24) {
        ForEach(PillSize.allCases) { size in
            VStack(spacing: 6) {
                Text(size.title).font(.caption).foregroundStyle(.secondary)
                DetailPillsRow(
                    cue: cue,
                    kinds: DetailPillKind.defaultOrder,
                    cueListName: "Main Cue List",
                    size: size
                )
            }
        }
    }
    .padding(40)
    .frame(width: 900)
}

/// The cue-type pill with its label switched off, next to a row that keeps it.
#Preview("Cue type without its label") {
    var cue = Cue(uniqueID: "t")
    cue.type = "Audio"
    cue.duration = 4.25

    return VStack(spacing: 24) {
        DetailPillsRow(
            cue: cue, kinds: DetailPillKind.defaultOrder, cueListName: "Main Cue List"
        )
        DetailPillsRow(
            cue: cue,
            kinds: DetailPillKind.defaultOrder,
            cueListName: "Main Cue List",
            showsCueTypeLabel: false
        )
    }
    .padding(40)
    .frame(width: 900)
}

/// Every cue type that carries a colour or a turned glyph, together so they
/// can be told apart at a glance — including Arm and Disarm, which share one
/// symbol and are distinguished by Disarm having it upside down and red.
///
/// Audio leads, uncoloured, as the baseline the rest are louder than.
#Preview("Cue type colours") {
    let types = [
        "Audio", "Start", "Stop", "Pause", "Group",
        "Load", "Fade", "Arm", "Disarm", "Reset", "Target",
    ]

    return VStack(spacing: 10) {
        ForEach(types, id: \.self) { type in
            var cue = Cue(uniqueID: type)
            cue.type = type
            return DetailPillsRow(cue: cue, kinds: [.cueType], cueListName: nil)
        }
    }
    .padding(40)
    .frame(width: 300)
}

/// The green group pill, and the note wide and centred on its own line.
#Preview("Group cue") {
    var child = Cue(uniqueID: "child")
    child.number = "13.1"

    var cue = Cue(uniqueID: "g")
    cue.number = "13"
    cue.name = "Act Two Preset"
    cue.listName = "Act Two Preset"
    cue.type = "Group"
    cue.children = [child]
    cue.notes = "Fires the whole preset — check the deck is clear before this one"

    return DetailPillsRow(
        cue: cue, kinds: DetailPillKind.defaultOrder, cueListName: "Main Cue List"
    )
    .padding(40)
    .frame(width: 900)
}

/// `F14` reproduction: a narrow window with a long cue-list name.
///
/// Every other preview here is 900pt wide, which is why this was never seen.
/// The audit's claim is that the pills occupy one non-wrapping row and treat
/// the list name as fixed-width content, so a long one pushes the row wider
/// than the window instead of giving way.
#Preview("Narrow window, long list name") {
    var cue = Cue(uniqueID: "n")
    cue.number = "12.5"
    cue.name = "Thunder Crash"
    cue.listName = "Thunder Crash"
    cue.type = "Audio"
    cue.duration = 4.25
    cue.preWait = 1.5
    cue.continueMode = .autoContinue
    cue.isFlagged = true
    cue.isArmed = false

    return DetailPillsRow(
        cue: cue,
        kinds: DetailPillKind.defaultOrder,
        cueListName: "Act Two — Understudy Track (Revised)"
    )
    .padding(20)
    // The narrowest the main window's detail pane realistically gets: the
    // sidebar's minimum is 220 of a 480pt window.
    .frame(width: 260)
}

/// A long note in a narrow window: the case the note pill's second candidate
/// exists for.
///
/// Sized to its own text, this note would be far wider than the window, so
/// ``ViewThatFits`` has to fall back to the pill that gives way and truncates.
/// Hugging is the preference, not the rule — a pill that hugged regardless
/// would hang off both edges of the window, which is the `F14` failure again
/// by a different route.
#Preview("Narrow window, long note") {
    var cue = Cue(uniqueID: "ln")
    cue.type = "Audio"
    cue.duration = 4.25
    cue.notes = "Hold for the door slam, then go on the lighting cue"

    return DetailPillsRow(
        cue: cue, kinds: DetailPillKind.defaultOrder, cueListName: "Effects"
    )
    .padding(20)
    .frame(width: 260)
}

/// An unnamed audio cue: QLab labels it with its file, and that is what the
/// display should call it too — while the Cue List pill still names the list.
#Preview("Unnamed cue") {
    var cue = Cue(uniqueID: "u")
    cue.number = "14"
    cue.listName = "rain-loop.wav"
    cue.type = "Audio"
    cue.duration = 120

    return DetailPillsRow(
        cue: cue, kinds: DetailPillKind.defaultOrder, cueListName: "Effects"
    )
    .padding(40)
    .frame(width: 900)
}
