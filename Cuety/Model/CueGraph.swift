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
        for (index, row) in cueList.children.enumerated() {
            Self.index(row, asRow: index, cues: &cues, rowIndices: &rowIndices)
        }
        self.cuesByID = cues
        self.rowIndexByCueID = rowIndices
    }

    /// Records a cue and everything inside it against the top-level row that
    /// contains them.
    private static func index(
        _ cue: Cue,
        asRow rowIndex: Int,
        cues: inout [String: Cue],
        rowIndices: inout [String: Int]
    ) {
        // First occurrence wins. QLab IDs are unique, but a defensive choice
        // here beats a crash on a duplicate.
        if cues[cue.uniqueID] == nil {
            cues[cue.uniqueID] = cue
            rowIndices[cue.uniqueID] = rowIndex
        }
        for child in cue.children {
            Self.index(child, asRow: rowIndex, cues: &cues, rowIndices: &rowIndices)
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
