import Foundation

/// A flattened, ordered view of one cue list, for O(1) playhead neighbourhood
/// lookups.
///
/// QLab hands us a tree; the display needs "the cue before this one" and "the
/// three cues after this one". Walking the tree for every drawer row on every
/// playhead change would be wasteful and, worse, would make the drawer's
/// ordering an emergent property of recursion rather than something explicit.
nonisolated struct CueGraph: Sendable {
    /// Cues in the order an operator would walk them, depth-first.
    let ordered: [Cue]

    /// Cue ID to index in ``ordered``.
    private let indexByID: [String: Int]

    let cueListID: String
    let cueListName: String?

    init(cueList: Cue) {
        self.cueListID = cueList.uniqueID
        self.cueListName = cueList.displayName

        var flattened: [Cue] = []
        Self.flatten(cueList.children, into: &flattened)
        self.ordered = flattened

        var index: [String: Int] = [:]
        index.reserveCapacity(flattened.count)
        for (offset, cue) in flattened.enumerated() {
            // First occurrence wins. QLab IDs are unique, but a defensive
            // choice here beats a crash on a duplicate.
            if index[cue.uniqueID] == nil { index[cue.uniqueID] = offset }
        }
        self.indexByID = index
    }

    /// Group cues appear in the sequence themselves, followed by their
    /// children — which is the order the playhead visits them in QLab.
    private static func flatten(_ cues: [Cue], into result: inout [Cue]) {
        for cue in cues {
            result.append(cue)
            if !cue.children.isEmpty {
                flatten(cue.children, into: &result)
            }
        }
    }

    var isEmpty: Bool { ordered.isEmpty }
    var count: Int { ordered.count }

    func index(of cueID: String) -> Int? { indexByID[cueID] }

    func cue(withID cueID: String) -> Cue? {
        indexByID[cueID].map { ordered[$0] }
    }

    /// The cues immediately before `cueID`, nearest last.
    ///
    /// Returns fewer than `count` near the start of the list — the drawer shows
    /// what exists rather than padding with blanks.
    func previous(before cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = indexByID[cueID] else { return [] }
        let start = max(0, index - count)
        guard start < index else { return [] }
        return Array(ordered[start..<index])
    }

    /// The cues immediately after `cueID`, nearest first.
    func upcoming(after cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = indexByID[cueID] else { return [] }
        let start = index + 1
        guard start < ordered.count else { return [] }
        let end = min(ordered.count, start + count)
        return Array(ordered[start..<end])
    }

    /// Whether `cueID` is the last cue in the list — the drawer says so
    /// explicitly rather than just showing nothing below the playhead.
    func isLast(_ cueID: String) -> Bool {
        guard let index = indexByID[cueID] else { return false }
        return index == ordered.count - 1
    }

    func isFirst(_ cueID: String) -> Bool {
        indexByID[cueID] == 0
    }
}
