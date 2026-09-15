import Foundation

nonisolated struct CueGraph: Sendable {
    let rows: [Cue]

    let cueNumbers: [String]

    private let cuesByID: [String: Cue]

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

    private static func index(
        _ cue: Cue,
        asRow rowIndex: Int,
        cues: inout [String: Cue],
        rowIndices: inout [String: Int],
        numbers: inout [String]
    ) {
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

    func cue(withID cueID: String) -> Cue? {
        cuesByID[cueID]
    }

    func containingRow(of cueID: String) -> Cue? {
        guard let index = rowIndexByCueID[cueID],
              rows[index].uniqueID != cueID
        else { return nil }
        return rows[index]
    }

    func rowsAbove(_ cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = rowIndexByCueID[cueID] else { return [] }
        let start = max(0, index - count)
        guard start < index else { return [] }
        return Array(rows[start..<index])
    }

    func rowsBelow(_ cueID: String, count: Int) -> [Cue] {
        guard count > 0, let index = rowIndexByCueID[cueID] else { return [] }
        let start = index + 1
        guard start < rows.count else { return [] }
        let end = min(rows.count, start + count)
        return Array(rows[start..<end])
    }

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

        let spareAbove = wantedAbove > 0
            ? min(wantedBelow - fittedBelow, availableAbove - fittedAbove) : 0
        let spareBelow = wantedBelow > 0
            ? min(wantedAbove - fittedAbove, availableBelow - fittedBelow) : 0

        return Neighbourhood(
            above: rowsAbove(cueID, count: fittedAbove + spareAbove),
            below: rowsBelow(cueID, count: fittedBelow + spareBelow)
        )
    }

    nonisolated struct Neighbourhood: Hashable, Sendable {
        let above: [Cue]

        let below: [Cue]

        var count: Int { above.count + below.count }
    }

    func isFirst(_ cueID: String) -> Bool {
        rows.first?.uniqueID == cueID
    }

    func isLast(_ cueID: String) -> Bool {
        rows.last?.uniqueID == cueID
    }
}
