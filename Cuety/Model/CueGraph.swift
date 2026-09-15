import Foundation

/// One cue list, indexed for the two questions the display asks of it: where a
/// cue sits, and what surrounds it.
///
/// QLab hands us a tree. The drawer wants "the row before this one" and "the
/// three rows after this one", and walking the tree for every row on every
/// playhead change would be wasteful and, worse, would make the drawer's
/// ordering an emergent property of recursion rather than something explicit.
///
/// Strictly *list position*. This is a snapshot of how a cue list reads top to
/// bottom, and that is all it can support: it knows nothing about what has
/// fired, and the order it produces is not a prediction of what the next GO
/// will do. Callers must not phrase its results as playback history or
/// execution order.
nonisolated struct CueGraph: Sendable {
    /// The cue list's top-level cues, in the order they read down the list.
    ///
    /// A group is *one* row and its children are not rows at all — the same
    /// shape the operator sees in QLab's own window, where a group is a single
    /// line until they open it. Flattening groups in here made a four-cue show
    /// with one group read as a dozen rows, which is not the list anybody is
    /// looking at.
    ///
    /// The children are still indexed, just not drawn: see
    /// ``cue(withID:)`` and ``rowIndexByCueID``.
    let rows: [Cue]

    /// Every cue number in the list, in the order the cues are indexed —
    /// groups, their children, and their children's children.
    ///
    /// Nested cues included, and for the same reason ``cue(withID:)`` includes
    /// them: the playhead can be parked inside a group, so any of these numbers
    /// can end up in the display's headline. The headline is sized to fit the
    /// widest of them, which is what keeps it one size for a whole cue list.
    let cueNumbers: [String]

    /// Every cue in the list by ID — groups, their children, and their
    /// children's children.
    private let cuesByID: [String: Cue]

    /// Every cue ID mapped to the index in ``rows`` of the top-level cue that
    /// contains it.
    ///
    /// A cue nested three groups deep maps to the outermost group's index, so
    /// a playhead parked inside a group still has a row to be positioned
    /// against. Without this the drawer would go blank the moment the operator
    /// stepped into a group.
    private let rowIndexByCueID: [String: Int]

    init(cueList: Cue) {
        self.rows = cueList.children

        var cues: [String: Cue] = [:]
        var rowIndices: [String: Int] = [:]
        var numbers: [String] = []
        for (index, row) in cueList.children.enumerated() {
            Self.index(
                row, asRow: index, cues: &cues, rowIndices: &rowIndices, numbers: &numbers
            )
        }
        self.cuesByID = cues
        self.rowIndexByCueID = rowIndices
        self.cueNumbers = numbers
    }

    /// Records a cue and everything inside it against the top-level row that
    /// contains them.
    private static func index(
        _ cue: Cue,
        asRow rowIndex: Int,
        cues: inout [String: Cue],
        rowIndices: inout [String: Int],
        numbers: inout [String]
    ) {
        // First occurrence wins. QLab IDs are unique, but a defensive choice
        // here beats a crash on a duplicate.
        if cues[cue.uniqueID] == nil {
            cues[cue.uniqueID] = cue
            rowIndices[cue.uniqueID] = rowIndex
            if let number = cue.displayNumber { numbers.append(number) }
        }
        for child in cue.children {
            Self.index(
                child, asRow: rowIndex, cues: &cues, rowIndices: &rowIndices, numbers: &numbers
            )
        }
    }

    /// The cue with this ID, wherever it sits — including inside a group.
    ///
    /// Deliberately not restricted to ``rows``. The playhead can be parked on
    /// a cue inside a group, and the display has to be able to name that cue
    /// even though the drawer draws its group instead of it.
    func cue(withID cueID: String) -> Cue? {
        cuesByID[cueID]
    }

    /// The group a cue sits inside, or `nil` when it is a top-level row
    /// itself — or when this list has never heard of it.
    ///
    /// The drawer uses this to say which group the playhead is in. It has to
    /// say *something*: the group is drawn as a single row and the cue at the
    /// playhead is not drawn at all, so without this the marker would appear
    /// to sit between two unrelated rows.
    func containingRow(of cueID: String) -> Cue? {
        guard let index = rowIndexByCueID[cueID],
              rows[index].uniqueID != cueID
        else { return nil }
        return rows[index]
    }

    /// The rows immediately above `cueID`'s row, nearest last.
    ///
    /// Returns fewer than `count` near the start of the list — the drawer shows
    /// what exists rather than padding with blanks.
    func rowsAbove(_ cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = rowIndexByCueID[cueID] else { return [] }
        let start = max(0, index - count)
        guard start < index else { return [] }
        return Array(rows[start..<index])
    }

    /// The rows immediately below `cueID`'s row, nearest first.
    func rowsBelow(_ cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = rowIndexByCueID[cueID] else { return [] }
        let start = index + 1
        guard start < rows.count else { return [] }
        let end = min(rows.count, start + count)
        return Array(rows[start..<end])
    }

    /// The rows either side of `cueID`, each side making up what the other
    /// could not fill.
    ///
    /// Near the end of a cue list there are not `below` rows left to show, and
    /// asking for them separately meant the drawer simply got shorter — the
    /// display shifting under the operator over the last few cues of a show,
    /// which is exactly when they are looking at it. The rows a side cannot
    /// use are spent on the other side instead, so the drawer holds its shape:
    /// three and three becomes five and one on the second-to-last row, and six
    /// and none on the last. The same at the top of the list, in the other
    /// direction.
    ///
    /// A side set to **zero** stays empty, and is not a place the other side's
    /// shortfall can go. Zero rows above is an instruction about what belongs
    /// on screen, not an arithmetic detail to be made up elsewhere — an
    /// operator who has said they never want to look backwards should not find
    /// six past cues in the drawer because the show reached its last cue.
    ///
    /// Returns fewer rows than asked for in total only when the list itself is
    /// too short to fill them: nothing is padded with blanks.
    func neighbourhood(around cueID: String, above: Int, below: Int) -> Neighbourhood {
        guard let index = rowIndexByCueID[cueID] else {
            return Neighbourhood(above: [], below: [])
        }

        let wantedAbove = max(0, above)
        let wantedBelow = max(0, below)
        let availableAbove = index
        let availableBelow = rows.count - index - 1

        let fittedAbove = min(wantedAbove, availableAbove)
        let fittedBelow = min(wantedBelow, availableBelow)

        // What each side asked for and the list could not give it, offered to
        // the other side up to the room that side has left.
        let spareAbove = wantedAbove > 0
            ? min(wantedBelow - fittedBelow, availableAbove - fittedAbove) : 0
        let spareBelow = wantedBelow > 0
            ? min(wantedAbove - fittedAbove, availableBelow - fittedBelow) : 0

        return Neighbourhood(
            above: rowsAbove(cueID, count: fittedAbove + spareAbove),
            below: rowsBelow(cueID, count: fittedBelow + spareBelow)
        )
    }

    /// The drawer's window onto the list: the rows either side of one cue.
    ///
    /// List position, like everything else here. Neither side is a record of
    /// what has fired or a prediction of what will.
    nonisolated struct Neighbourhood: Hashable, Sendable {
        /// The rows above, nearest last — so the final element is the row
        /// directly above the cue.
        let above: [Cue]

        /// The rows below, nearest first.
        let below: [Cue]

        /// How many rows in total, the cue's own row aside.
        var count: Int { above.count + below.count }
    }

    /// Whether `cueID` *is* the first row of the list.
    ///
    /// The drawer says so explicitly rather than just showing nothing above
    /// the playhead — which would otherwise be indistinguishable from a drawer
    /// configured to show no rows above it at all.
    ///
    /// Strict: a cue inside the first group is not the first row, and must not
    /// be described as the top of the cue list, because there is a group cue
    /// above it that this drawer is showing.
    func isFirst(_ cueID: String) -> Bool {
        rows.first?.uniqueID == cueID
    }

    /// Whether `cueID` *is* the last row of the list.
    ///
    /// Strict, for the same reason as ``isFirst(_:)`` — and with more at
    /// stake, since the display prints "End of List" from this. A playhead
    /// inside the final group has cues after it inside that group, so claiming
    /// the end of the list would be false.
    func isLast(_ cueID: String) -> Bool {
        rows.last?.uniqueID == cueID
    }
}
