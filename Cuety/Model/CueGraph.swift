import Foundation

/// The stable shape of a cue list. Cue values stay in `QLabClient.cueLists`;
/// the graph keeps only the paths needed to find them and display row order.
nonisolated struct CueGraph: Sendable {
    let cueListID: String
    let rowIDs: [String]
    private let pathByCueID: [String: [Int]]
    private var numberedCueIDs: [String]
    private(set) var cueNumbers: [String]

    init(cueList: Cue) {
        cueListID = cueList.uniqueID
        rowIDs = cueList.children.map(\.uniqueID)

        var paths: [String: [Int]] = [:]
        var numberedIDs: [String] = []
        var numbers: [String] = []

        func index(_ cues: [Cue], prefix: [Int]) {
            for (rowIndex, cue) in cues.enumerated() {
                let path = prefix + [rowIndex]
                if paths[cue.uniqueID] == nil {
                    paths[cue.uniqueID] = path
                    if let number = cue.displayNumber {
                        numberedIDs.append(cue.uniqueID)
                        numbers.append(number)
                    }
                }
                index(cue.children, prefix: path)
            }
        }

        index(cueList.children, prefix: [])
        pathByCueID = paths
        numberedCueIDs = numberedIDs
        cueNumbers = numbers
    }

    /// Resolves a path against the current value tree. The path is never used
    /// as a retained cue snapshot, and stale paths fail closed on ID mismatch.
    func cue(withID cueID: String, in currentList: Cue?) -> Cue? {
        guard currentList?.uniqueID == cueListID,
              let path = pathByCueID[cueID],
              !path.isEmpty,
              var cues = currentList?.children else { return nil }

        var cue: Cue?
        for (depth, index) in path.enumerated() {
            guard cues.indices.contains(index) else { return nil }
            cue = cues[index]
            if depth < path.count - 1 {
                cues = cue?.children ?? []
            }
        }
        guard cue?.uniqueID == cueID else { return nil }
        return cue
    }

    func path(for cueID: String) -> [Int]? {
        pathByCueID[cueID]
    }

    /// The top-level row containing a cue, or the cue's own row when it is
    /// already at the top level.
    func rowIndex(of cueID: String) -> Int? {
        pathByCueID[cueID]?.first
    }

    func containingRowID(of cueID: String) -> String? {
        guard let path = pathByCueID[cueID], path.count > 1,
              rowIDs.indices.contains(path[0]) else { return nil }
        return rowIDs[path[0]]
    }

    func rowsAbove(_ cueID: String, count: Int) -> [String] {
        guard count > 0, let index = rowIndex(of: cueID) else { return [] }
        let start = max(0, index - count)
        guard start < index else { return [] }
        return Array(rowIDs[start..<index])
    }

    func rowsBelow(_ cueID: String, count: Int) -> [String] {
        guard count > 0, let index = rowIndex(of: cueID) else { return [] }
        let start = index + 1
        guard start < rowIDs.count else { return [] }
        let end = min(rowIDs.count, start + count)
        return Array(rowIDs[start..<end])
    }

    func neighbourhood(around cueID: String, above: Int, below: Int) -> Neighbourhood {
        guard let index = rowIndex(of: cueID) else {
            return Neighbourhood(above: [], below: [])
        }

        let wantedAbove = max(0, above)
        let wantedBelow = max(0, below)
        let availableAbove = index
        let availableBelow = rowIDs.count - index - 1

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
        let above: [String]
        let below: [String]
        var count: Int { above.count + below.count }
    }

    func isFirst(_ cueID: String) -> Bool {
        rowIDs.first == cueID
    }

    func isLast(_ cueID: String) -> Bool {
        rowIDs.last == cueID
    }

    /// Refreshes the number projection without rebuilding cue paths.
    mutating func applyCueNumberUpdates(_ updates: [CueNumberUpdate]) {
        for update in updates {
            guard let path = pathByCueID[update.cueID] else { continue }
            if let number = update.displayNumber {
                if let currentIndex = numberedCueIDs.firstIndex(of: update.cueID) {
                    cueNumbers[currentIndex] = number
                    continue
                }
                let insertionIndex = numberedCueIDs.firstIndex { cueID in
                    guard let otherPath = pathByCueID[cueID] else { return false }
                    return otherPath.lexicographicallyPrecedes(path)
                } ?? numberedCueIDs.endIndex
                numberedCueIDs.insert(update.cueID, at: insertionIndex)
                cueNumbers.insert(number, at: insertionIndex)
            } else if let currentIndex = numberedCueIDs.firstIndex(of: update.cueID) {
                numberedCueIDs.remove(at: currentIndex)
                cueNumbers.remove(at: currentIndex)
            }
        }
    }
}
