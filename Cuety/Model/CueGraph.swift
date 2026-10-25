import Foundation

/// The stable shape of a cue list. Cue values stay in `QLabClient.cueLists`;
/// the graph keeps only the paths needed to find them and display row order.
nonisolated struct CueGraph: Sendable {
    let cueListID: String
    let rowIDs: [String]
    private let pathByCueID: [String: [Int]]
    private(set) var cueNumbersByID: [String: String]

    var cueNumbers: [String] {
        cueNumbersByID.keys
            .sorted {
                guard let lhs = pathByCueID[$0], let rhs = pathByCueID[$1] else { return false }
                return lhs.lexicographicallyPrecedes(rhs)
            }
            .compactMap { cueNumbersByID[$0] }
    }

    init(cueList: Cue) {
        cueListID = cueList.uniqueID
        rowIDs = cueList.children.map(\.uniqueID)

        var paths: [String: [Int]] = [:]
        var numbersByID: [String: String] = [:]

        func index(_ cues: [Cue], prefix: [Int]) {
            for (rowIndex, cue) in cues.enumerated() {
                let path = prefix + [rowIndex]
                if paths[cue.uniqueID] == nil {
                    paths[cue.uniqueID] = path
                    if let number = cue.displayNumber {
                        numbersByID[cue.uniqueID] = number
                    }
                }
                index(cue.children, prefix: path)
            }
        }

        index(cueList.children, prefix: [])
        pathByCueID = paths
        cueNumbersByID = numbersByID
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

    var allPaths: [String: [Int]] { pathByCueID }

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
        for update in updates where pathByCueID[update.cueID] != nil {
            cueNumbersByID[update.cueID] = update.displayNumber
        }
    }
}
nonisolated struct WorkspaceIndex: Sendable {
    struct Location: Sendable {
        let listIndex: Int
        let cueListID: String
        let path: [Int]
    }

    private(set) var locationsByCueID: [String: Location] = [:]
    private(set) var graphsByListID: [String: CueGraph] = [:]

    init(cueLists: [Cue]) {
        for (listIndex, list) in cueLists.enumerated() {
            let graph = CueGraph(cueList: list)
            graphsByListID[list.uniqueID] = graph
            for (cueID, path) in graph.allPaths where locationsByCueID[cueID] == nil {
                locationsByCueID[cueID] = Location(
                    listIndex: listIndex,
                    cueListID: list.uniqueID,
                    path: path
                )
            }
        }
    }

    func contains(_ cueID: String) -> Bool {
        locationsByCueID[cueID] != nil
    }

    func cueListID(containing cueID: String) -> String? {
        locationsByCueID[cueID]?.cueListID
    }

    func cue(withID cueID: String, in cueLists: [Cue]) -> Cue? {
        guard let location = locationsByCueID[cueID],
              cueLists.indices.contains(location.listIndex),
              let graph = graphsByListID[location.cueListID]
        else { return nil }
        return graph.cue(withID: cueID, in: cueLists[location.listIndex])
    }

    mutating func applyCueNumberUpdates(_ updates: [CueNumberUpdate]) {
        for listID in graphsByListID.keys {
            guard var graph = graphsByListID[listID] else { continue }
            graph.applyCueNumberUpdates(updates)
            graphsByListID[listID] = graph
        }
    }
}
