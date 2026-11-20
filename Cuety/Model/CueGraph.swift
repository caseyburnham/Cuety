import Foundation

/// The stable shape of a cue list. Cue values stay in `QLabClient.cueLists`;
/// the graph keeps only the paths needed to find them and display row order.
nonisolated struct CueGraph: Sendable {
    let graphID: UUID
    let cueListID: String
    let rowIDs: [String]
    let nodeCount: Int
    private let pathByCueID: [String: [Int]]
    private var numberedCueIDs: [String]
    private(set) var cueNumbers: [String]
    private(set) var numbersVersion: UInt64

    init(cueList: Cue, reusing previous: CueGraph? = nil) {
        cueListID = cueList.uniqueID
        rowIDs = cueList.children.map(\.uniqueID)

        var paths: [String: [Int]] = [:]
        var numberedIDs: [String] = []
        var numbers: [String] = []
        var count = 0

        func index(_ cues: [Cue], prefix: [Int]) {
            for (rowIndex, cue) in cues.enumerated() {
                count += 1
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
        nodeCount = count
        pathByCueID = paths
        numberedCueIDs = numberedIDs
        cueNumbers = numbers

        if let previous,
           previous.cueListID == cueList.uniqueID,
           previous.rowIDs == rowIDs,
           previous.pathByCueID == paths {
            graphID = previous.graphID
            numbersVersion = previous.cueNumbers == numbers
                ? previous.numbersVersion
                : previous.numbersVersion &+ 1
        } else {
            graphID = UUID()
            numbersVersion = 0
        }
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
        var didChange = false
        for update in updates {
            guard let path = pathByCueID[update.cueID] else { continue }

            if let number = update.displayNumber {
                if let currentIndex = numberedCueIDs.firstIndex(of: update.cueID) {
                    if cueNumbers[currentIndex] != number {
                        cueNumbers[currentIndex] = number
                        didChange = true
                    }
                    continue
                }

                let insertionIndex = numberedCueIDs.firstIndex { cueID in
                    guard let otherPath = pathByCueID[cueID] else { return false }
                    return path.lexicographicallyPrecedes(otherPath)
                } ?? numberedCueIDs.endIndex
                numberedCueIDs.insert(update.cueID, at: insertionIndex)
                cueNumbers.insert(number, at: insertionIndex)
                didChange = true
            } else if let currentIndex = numberedCueIDs.firstIndex(of: update.cueID) {
                numberedCueIDs.remove(at: currentIndex)
                cueNumbers.remove(at: currentIndex)
                didChange = true
            }
        }
        if didChange {
            numbersVersion &+= 1
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
    private(set) var listIndicesByID: [String: Int] = [:]
    private(set) var graphsByListID: [String: CueGraph] = [:]
    let totalCueCount: Int

    init(cueLists: [Cue], reusing previous: WorkspaceIndex? = nil) {
        var count = 0
        for (listIndex, list) in cueLists.enumerated() {
            count += 1
            if listIndicesByID[list.uniqueID] == nil {
                listIndicesByID[list.uniqueID] = listIndex
            }
            let graph = CueGraph(
                cueList: list,
                reusing: previous?.graphsByListID[list.uniqueID]
            )
            count += graph.nodeCount
            graphsByListID[list.uniqueID] = graph
            for (cueID, path) in graph.allPaths where locationsByCueID[cueID] == nil {
                locationsByCueID[cueID] = Location(
                    listIndex: listIndex,
                    cueListID: list.uniqueID,
                    path: path
                )
            }
        }
        totalCueCount = count
    }

    func contains(_ cueID: String) -> Bool {
        locationsByCueID[cueID] != nil || listIndicesByID[cueID] != nil
    }

    func cueListID(containing cueID: String) -> String? {
        locationsByCueID[cueID]?.cueListID
    }

    func graph(forListID listID: String) -> CueGraph? {
        graphsByListID[listID]
    }

    func cueList(withID listID: String, in cueLists: [Cue]) -> Cue? {
        guard let listIndex = listIndicesByID[listID],
              cueLists.indices.contains(listIndex),
              cueLists[listIndex].uniqueID == listID
        else { return nil }
        return cueLists[listIndex]
    }

    func cue(withID cueID: String, in cueLists: [Cue]) -> Cue? {
        if let location = locationsByCueID[cueID],
           cueLists.indices.contains(location.listIndex),
           let graph = graphsByListID[location.cueListID],
           let found = graph.cue(withID: cueID, in: cueLists[location.listIndex]) {
            return found
        }
        return cueList(withID: cueID, in: cueLists)
    }

    func cues(withIDs ids: Set<String>, in cueLists: [Cue]) -> [String: Cue] {
        guard !ids.isEmpty else { return [:] }
        var found: [String: Cue] = [:]
        found.reserveCapacity(ids.count)
        for id in ids {
            if let cue = cue(withID: id, in: cueLists) {
                found[id] = cue
            }
        }
        return found
    }

    mutating func applyCueNumberUpdates(_ updates: [CueNumberUpdate]) {
        guard !updates.isEmpty else { return }
        var updatesByListID: [String: [CueNumberUpdate]] = [:]
        for update in updates {
            guard let listID = locationsByCueID[update.cueID]?.cueListID else { continue }
            updatesByListID[listID, default: []].append(update)
        }
        for (listID, listUpdates) in updatesByListID {
            graphsByListID[listID]?.applyCueNumberUpdates(listUpdates)
        }
    }
}
