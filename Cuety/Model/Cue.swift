import SwiftUI

nonisolated struct QLabWorkspaceInfo: Decodable, Hashable, Sendable, Identifiable {
    let uniqueID: String
    let displayName: String
    let port: Int?
    let version: String?

    var id: String { uniqueID }
}

nonisolated struct Cue: Hashable, Sendable, Identifiable {
    let uniqueID: String

    var number: String?

    var name: String?

    var listName: String?

    var type: String?
    var colorName: String?
    var isFlagged: Bool?
    var isArmed: Bool?

    var notes: String?
    var duration: TimeInterval?
    var preWait: TimeInterval?
    var postWait: TimeInterval?
    var continueMode: ContinueMode?

    /// QLab cannot fire this cue — a missing file, a lost patch, a target
    /// that no longer exists.
    var isBroken: Bool?

    /// QLab has loaded this cue, so it is standing by at its load point.
    var isLoaded: Bool?

    var children: [Cue] = []

    var id: String { uniqueID }

    init(uniqueID: String) {
        self.uniqueID = uniqueID
    }

    var isGroup: Bool { !children.isEmpty || type?.caseInsensitiveCompare("group") == .orderedSame }

    /// A top-level cue cart. `/cueLists` returns carts alongside cue lists,
    /// but a cart has no playhead, so QLab rejects `playbackPositionID` for it.
    var isCueCart: Bool {
        guard let type else { return false }
        return type.caseInsensitiveCompare("cart") == .orderedSame
            || type.caseInsensitiveCompare("cue cart") == .orderedSame
    }

    var displayNumber: String? {
        Self.trimmedNonEmpty(number)
    }

    var displayName: String? {
        Self.trimmedNonEmpty(name) ?? Self.trimmedNonEmpty(listName)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value, value.contains(where: { !$0.isWhitespace }) else { return nil }
        return value
    }

    var color: Color? {
        guard let colorName, !colorName.isEmpty else { return nil }
        if let qlabColor = QLabCueColor(rawValue: colorName) {
            return qlabColor.color
        }
        guard colorName.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }),
              let qlabColor = QLabCueColor(rawValue: colorName.lowercased()) else {
            return nil
        }
        return qlabColor.color
    }
}

nonisolated enum PlayheadState: Hashable, Sendable {
    case cue(String)
    case unset
    case unknown(reason: String)

    var cueID: String? {
        guard case .cue(let id) = self else { return nil }
        return id
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

nonisolated enum ContinueMode: Int, Hashable, Sendable {
    case doNotContinue = 0
    case autoContinue = 1
    case autoFollow = 2

    var title: String {
        switch self {
        case .doNotContinue: "No Continue"
        case .autoContinue: "Auto-Continue"
        case .autoFollow: "Auto-Follow"
        }
    }

    var systemImage: String {
        switch self {
        case .doNotContinue: "stop.circle"
        case .autoContinue: "arrow.down"
        case .autoFollow: "square.and.arrow.down"
        }
    }
}

nonisolated struct QLabCueValues: Decodable, Sendable {
    var number: String?
    var name: String?
    var listName: String?
    var type: String?
    var colorName: String?
    var flagged: Bool?
    var armed: Bool?
    var notes: String?
    var duration: Double?
    var preWait: Double?
    var postWait: Double?
    var continueMode: Int?
    var isBroken: Bool?
    var isLoaded: Bool?
}

nonisolated struct CueNumberUpdate: Sendable {
    let cueID: String
    let displayNumber: String?
}

nonisolated struct CueValueChanges: Sendable {
    let foundCueIDs: Set<String>
    let changedCueIDs: Set<String>
    let cueNumberUpdates: [CueNumberUpdate]
}

nonisolated extension Cue {
    /// The retained `/valuesForKeys` details that `incoming` left empty.
    /// Identity fields always arrive with `/cueLists`, and any detail that
    /// reply did supply is fresher, so neither is overwritten with older data.
    func detailValues(missingFrom incoming: Cue) -> QLabCueValues {
        QLabCueValues(
            notes: incoming.notes == nil ? notes : nil,
            duration: incoming.duration == nil ? duration : nil,
            preWait: incoming.preWait == nil ? preWait : nil,
            postWait: incoming.postWait == nil ? postWait : nil,
            continueMode: incoming.continueMode == nil ? continueMode?.rawValue : nil,
            isBroken: incoming.isBroken == nil ? isBroken : nil,
            isLoaded: incoming.isLoaded == nil ? isLoaded : nil
        )
    }

    /// Takes every value `values` supplies, leaving the rest alone.
    /// - Returns: Whether anything changed.
    @discardableResult
    mutating func apply(_ values: QLabCueValues) -> Bool {
        var changed = false

        func take<Value: Equatable>(_ value: Value?, for keyPath: WritableKeyPath<Cue, Value?>) {
            guard let value, self[keyPath: keyPath] != value else { return }
            self[keyPath: keyPath] = value
            changed = true
        }

        take(values.number, for: \.number)
        take(values.name, for: \.name)
        take(values.listName, for: \.listName)
        take(values.type, for: \.type)
        take(values.colorName, for: \.colorName)
        take(values.flagged, for: \.isFlagged)
        take(values.armed, for: \.isArmed)
        take(values.notes, for: \.notes)
        take(values.duration, for: \.duration)
        take(values.preWait, for: \.preWait)
        take(values.postWait, for: \.postWait)
        take(values.continueMode.flatMap(ContinueMode.init(rawValue:)), for: \.continueMode)
        take(values.isBroken, for: \.isBroken)
        take(values.isLoaded, for: \.isLoaded)

        return changed
    }
}

nonisolated extension Array<Cue> {
    /// Applies a whole batch of replies in one traversal, rather than one
    /// search of the tree per cue. Returns the IDs whose values changed.
    @discardableResult
    mutating func applyValues(_ valuesByID: [String: QLabCueValues]) -> Set<String> {
        applyValuesAndFindCues(valuesByID, using: nil).changedCueIDs
    }

    /// Uses the workspace index's paths for O(1) cue resolution across every
    /// cue list, then falls back to a single traversal for any unindexed IDs.
    mutating func applyValuesAndFindCues(
        _ valuesByID: [String: QLabCueValues], using index: WorkspaceIndex
    ) -> CueValueChanges {
        applyValuesAndFindCues(valuesByID) { cueID, lists, body in
            if let location = index.locationsByCueID[cueID],
               lists.indices.contains(location.listIndex),
               lists[location.listIndex].uniqueID == location.cueListID {
                return Self.mutateCue(
                    withID: cueID,
                    at: location.path[...],
                    in: &lists[location.listIndex].children,
                    body: body
                )
            }
            if let listIndex = index.listIndicesByID[cueID],
               lists.indices.contains(listIndex),
               lists[listIndex].uniqueID == cueID {
                body(&lists[listIndex])
                return true
            }
            return false
        }
    }

    /// Uses the watched list's paths for the common case, then finds any
    /// remaining IDs in one traversal of the current tree.
    mutating func applyValuesAndFindCues(
        _ valuesByID: [String: QLabCueValues], using graph: CueGraph?
    ) -> CueValueChanges {
        let listIndex = graph.flatMap { graph in
            firstIndex(where: { $0.uniqueID == graph.cueListID })
        }
        return applyValuesAndFindCues(valuesByID) { cueID, lists, body in
            guard let graph, let listIndex,
                  let cuePath = graph.path(for: cueID) else { return false }
            return Self.mutateCue(
                withID: cueID,
                at: cuePath[...],
                in: &lists[listIndex].children,
                body: body
            )
        }
    }

    private mutating func applyValuesAndFindCues(
        _ valuesByID: [String: QLabCueValues],
        fastPath: (String, inout [Cue], (inout Cue) -> Void) -> Bool
    ) -> CueValueChanges {
        guard !valuesByID.isEmpty else {
            return CueValueChanges(foundCueIDs: [], changedCueIDs: [], cueNumberUpdates: [])
        }

        var remaining = Set(valuesByID.keys)
        var found = Set<String>()
        var changed = Set<String>()
        var numberUpdates: [CueNumberUpdate] = []

        func updateIfChanged(_ cue: inout Cue, with values: QLabCueValues) {
            let oldNumber = cue.displayNumber
            var updated = cue
            guard updated.apply(values) else { return }
            cue = updated
            changed.insert(cue.uniqueID)
            if oldNumber != updated.displayNumber {
                numberUpdates.append(
                    CueNumberUpdate(cueID: cue.uniqueID, displayNumber: updated.displayNumber)
                )
            }
        }

        for (cueID, values) in valuesByID {
            guard fastPath(cueID, &self, { updateIfChanged(&$0, with: values) }) else {
                continue
            }
            found.insert(cueID)
            remaining.remove(cueID)
        }

        // Fallback: single traversal for any cues whose paths changed or were unindexed.
        if !remaining.isEmpty {
            func visit(_ cues: inout [Cue]) {
                guard !remaining.isEmpty else { return }
                for index in cues.indices {
                    let cueID = cues[index].uniqueID
                    if remaining.remove(cueID) != nil, let values = valuesByID[cueID] {
                        found.insert(cueID)
                        updateIfChanged(&cues[index], with: values)
                    }
                    guard !remaining.isEmpty else { return }
                    visit(&cues[index].children)
                }
            }
            visit(&self)
        }

        return CueValueChanges(
            foundCueIDs: found,
            changedCueIDs: changed,
            cueNumberUpdates: numberUpdates
        )
    }

    /// Walks down the path and invokes body on the target cue if its ID matches.
    /// Returns true if the cue was found at the path.
    private static func mutateCue(
        withID cueID: String,
        at path: ArraySlice<Int>,
        in cues: inout [Cue],
        body: (inout Cue) -> Void
    ) -> Bool {
        guard let index = path.first, cues.indices.contains(index) else { return false }
        if path.count == 1 {
            guard cues[index].uniqueID == cueID else { return false }
            body(&cues[index])
            return true
        }
        return mutateCue(
            withID: cueID,
            at: path.dropFirst(),
            in: &cues[index].children,
            body: body
        )
    }

    /// Every cue among `ids`, gathered in one traversal.
    func cues(withIDs ids: Set<String>) -> [String: Cue] {
        var found: [String: Cue] = [:]
        guard !ids.isEmpty else { return found }

        func visit(_ cues: [Cue]) {
            for cue in cues {
                if ids.contains(cue.uniqueID) { found[cue.uniqueID] = cue }
                visit(cue.children)
            }
        }

        visit(self)
        return found
    }

    /// Carries retained details from `previous` onto the matching cues of
    /// this freshly fetched tree in one traversal, never overwriting a value
    /// the new reply supplied. Returns the IDs that were still present.
    mutating func carryDetails(from previous: [String: Cue]) -> Set<String> {
        var carried = Set<String>()
        guard !previous.isEmpty else { return carried }

        func visit(_ cues: inout [Cue]) {
            for index in cues.indices {
                if let old = previous[cues[index].uniqueID] {
                    cues[index].apply(old.detailValues(missingFrom: cues[index]))
                    carried.insert(cues[index].uniqueID)
                }
                visit(&cues[index].children)
            }
        }

        visit(&self)
        return carried
    }

    func firstCue(withID cueID: String) -> Cue? {
        for cue in self {
            if cue.uniqueID == cueID { return cue }
            if let found = cue.children.firstCue(withID: cueID) { return found }
        }
        return nil
    }

    func cueList(containing cueID: String) -> Cue? {
        first { $0.children.firstCue(withID: cueID) != nil }
    }
}

nonisolated extension Cue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case uniqueID
        case number
        case name
        case listName
        case type
        case colorName
        case flagged
        case armed
        case notes
        case duration
        case preWait
        case postWait
        case continueMode
        case cues
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        uniqueID = try container.decode(String.self, forKey: .uniqueID)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        listName = try container.decodeIfPresent(String.self, forKey: .listName)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .flagged)
        isArmed = try container.decodeIfPresent(Bool.self, forKey: .armed)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        preWait = try container.decodeIfPresent(Double.self, forKey: .preWait)
        postWait = try container.decodeIfPresent(Double.self, forKey: .postWait)
        continueMode = try container.decodeIfPresent(Int.self, forKey: .continueMode)
            .flatMap(ContinueMode.init(rawValue:))
        children = try container.decodeIfPresent([Cue].self, forKey: .cues) ?? []
    }
}
