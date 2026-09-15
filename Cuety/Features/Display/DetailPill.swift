import SwiftUI

struct DetailPill: View {
    let kind: DetailPillKind
    let cue: Cue

    let cueListName: String?

    var size: PillSize = .medium

    var showsCueTypeLabel = true

    var body: some View {
        if let content = Self.content(for: kind, cue: cue, cueListName: cueListName) {
            if content.isFlexible {
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
            .fixedSize(horizontal: hugsText || !content.isFlexible, vertical: false)
            .layoutPriority(content.isFlexible ? -1 : 0)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(Self.glass(for: content), in: .capsule)
            .help(content.help)
            .accessibilityLabel("\(kind.title): \(content.text)")
    }

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

    private func showsText(for kind: DetailPillKind) -> Bool {
        kind != .cueType || showsCueTypeLabel
    }

    static let flexibleTextMaxWidth: CGFloat = 520

    private static func glass(for content: Content) -> Glass {
        guard let tint = content.tint else { return .regular }
        return Glass.regular.tint(tint.opacity(0.28))
    }

    struct Content {
        let text: String
        let systemImage: String
        var tint: Color?
        var glyphTint: Color?
        var help: String
        var isFlexible = false
        var glyphRotation: Angle = .zero
        var hidesGlyph = false
        var isCentred = false
    }

    static func content(
        for kind: DetailPillKind, cue: Cue, cueListName: String?
    ) -> Content? {
        switch kind {
        case .cueType:
            guard let type = cue.type, !type.isEmpty else { return nil }
            let colours = colours(forCueType: type, isGroup: cue.isGroup)
            return Content(
                text: type,
                systemImage: systemImage(forCueType: type),
                tint: colours.pill,
                glyphTint: colours.glyph,
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
            guard let mode = cue.continueMode, mode != .doNotContinue else { return nil }
            return Content(
                text: mode.title,
                systemImage: mode.systemImage,
                tint: .blue,
                help: "This cue continues automatically"
            )

        case .cueList:
            guard let cueListName, !cueListName.isEmpty else { return nil }
            return Content(
                text: cueListName,
                systemImage: kind.systemImage,
                help: "Cue list",
                isFlexible: true
            )

        case .armed:
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

    static func colours(
        forCueType type: String, isGroup: Bool
    ) -> (pill: Color?, glyph: Color?) {
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

    static func glyphRotation(forCueType type: String) -> Angle {
        type.lowercased() == "disarm" ? .degrees(180) : .zero
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return interval.formatted(.number.precision(.fractionLength(interval < 10 ? 1 : 0))) + "s"
        }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

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

struct DetailPillsRow: View {
    let cue: Cue
    let kinds: [DetailPillKind]
    let cueListName: String?

    var size: PillSize = .medium

    var showsCueTypeLabel = true

    @Namespace private var glassNamespace

    private var populated: [DetailPillKind] {
        kinds.filter { DetailPill.content(for: $0, cue: cue, cueListName: cueListName) != nil }
    }

    private var inlineKinds: [DetailPillKind] {
        populated.filter { $0 != .notes }
    }

    private var noteKind: DetailPillKind? {
        populated.contains(.notes) ? .notes : nil
    }

    var body: some View {
        if !populated.isEmpty {
            GlassEffectContainer(spacing: size.glassSpacing) {
                VStack(spacing: size.spacing) {
                    if !inlineKinds.isEmpty {
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
    .frame(width: 260)
}

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
