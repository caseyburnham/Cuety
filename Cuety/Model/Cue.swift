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
        guard let number, !number.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return number
    }

    var displayName: String? {
        Self.trimmedNonEmpty(name) ?? Self.trimmedNonEmpty(listName)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    var color: Color? {
        guard let colorName = colorName?.lowercased(),
              let qlabColor = QLabCueColor(rawValue: colorName) else {
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

    /// Uses the watched list's paths for the common case, then finds any
    /// remaining IDs in one traversal of the current tree.
    mutating func applyValuesAndFindCues(
        _ valuesByID: [String: QLabCueValues], using graph: CueGraph?
    ) -> CueValueChanges {
        guard !valuesByID.isEmpty else {
            return CueValueChanges(foundCueIDs: [], changedCueIDs: [], cueNumberUpdates: [])
        }

        var remaining = Set(valuesByID.keys)
        var candidateCues: [String: Cue] = [:]
        var candidatePaths: [String: [Int]] = [:]

        if let graph, let listIndex = firstIndex(where: { $0.uniqueID == graph.cueListID }) {
            for cueID in valuesByID.keys.sorted() where remaining.contains(cueID) {
                guard let cuePath = graph.path(for: cueID) else { continue }
                let path = [listIndex] + cuePath
                guard let cue = Self.cue(at: path[...], in: self), cue.uniqueID == cueID else {
                    continue
                }
                candidateCues[cueID] = cue
                candidatePaths[cueID] = path
                remaining.remove(cueID)
            }
        }

        if !remaining.isEmpty {
            func visit(_ cues: [Cue], prefix: [Int]) {
                guard !remaining.isEmpty else { return }
                for (index, cue) in cues.enumerated() {
                    let path = prefix + [index]
                    if remaining.contains(cue.uniqueID) {
                        candidateCues[cue.uniqueID] = cue
                        candidatePaths[cue.uniqueID] = path
                        remaining.remove(cue.uniqueID)
                    }
                    guard !remaining.isEmpty else { return }
                    visit(cue.children, prefix: path)
                }
            }

            visit(self, prefix: [])
        }

        var changedValues: [String: QLabCueValues] = [:]
        var changed = Set<String>()
        var numberUpdates: [CueNumberUpdate] = []

        for cueID in candidateCues.keys.sorted() {
            guard let values = valuesByID[cueID], var updatedCue = candidateCues[cueID],
                  updatedCue.apply(values) else { continue }
            changed.insert(cueID)
            changedValues[cueID] = values
            if candidateCues[cueID]?.displayNumber != updatedCue.displayNumber {
                numberUpdates.append(
                    CueNumberUpdate(cueID: cueID, displayNumber: updatedCue.displayNumber)
                )
            }
        }

        // Compare first so an identical reply never makes any nested cue array
        // mutable. Only changed cue paths are written, and the root publishes
        // once after the complete batch has been applied.
        for cueID in changed.sorted() {
            guard let path = candidatePaths[cueID], let values = changedValues[cueID] else {
                continue
            }
            Self.apply(values, forCueID: cueID, at: path[...], in: &self)
        }

        return CueValueChanges(
            foundCueIDs: Set(candidateCues.keys),
            changedCueIDs: changed,
            cueNumberUpdates: numberUpdates
        )
    }

    private static func cue(at path: ArraySlice<Int>, in cues: [Cue]) -> Cue? {
        guard let index = path.first, cues.indices.contains(index) else { return nil }
        guard path.count > 1 else { return cues[index] }
        return cue(at: path.dropFirst(), in: cues[index].children)
    }

    private static func apply(
        _ values: QLabCueValues, forCueID cueID: String, at path: ArraySlice<Int>, in cues: inout [Cue]
    ) {
        guard let index = path.first, cues.indices.contains(index) else { return }
        if path.count == 1 {
            guard cues[index].uniqueID == cueID else { return }
            _ = cues[index].apply(values)
            return
        }
        apply(
            values, forCueID: cueID, at: path.dropFirst(), in: &cues[index].children
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
