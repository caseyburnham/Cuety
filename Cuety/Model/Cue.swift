import SwiftUI

nonisolated struct QLabWorkspaceInfo: Decodable, Hashable, Sendable, Identifiable {
    let uniqueID: String
    let displayName: String
    let port: Int?
    let version: String?

    var id: String { uniqueID }

    private enum CodingKeys: String, CodingKey {
        case uniqueID
        case displayName
        case port
        case version
    }
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

nonisolated enum ContinueMode: Int, Hashable, Sendable, Codable {
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

    @discardableResult
    mutating func apply(_ values: QLabCueValues) -> Bool {
        var changed = false

        if let number = values.number, self.number != number {
            self.number = number
            changed = true
        }
        if let name = values.name, self.name != name {
            self.name = name
            changed = true
        }
        if let listName = values.listName, self.listName != listName {
            self.listName = listName
            changed = true
        }
        if let type = values.type, self.type != type {
            self.type = type
            changed = true
        }
        if let colorName = values.colorName, self.colorName != colorName {
            self.colorName = colorName
            changed = true
        }
        if let flagged = values.flagged, self.isFlagged != flagged {
            self.isFlagged = flagged
            changed = true
        }
        if let armed = values.armed, self.isArmed != armed {
            self.isArmed = armed
            changed = true
        }
        if let notes = values.notes, self.notes != notes {
            self.notes = notes
            changed = true
        }
        if let duration = values.duration, self.duration != duration {
            self.duration = duration
            changed = true
        }
        if let preWait = values.preWait, self.preWait != preWait {
            self.preWait = preWait
            changed = true
        }
        if let postWait = values.postWait, self.postWait != postWait {
            self.postWait = postWait
            changed = true
        }
        if let mode = values.continueMode.flatMap(ContinueMode.init(rawValue:)),
           self.continueMode != mode {
            self.continueMode = mode
            changed = true
        }
        if let broken = values.isBroken, self.isBroken != broken {
            self.isBroken = broken
            changed = true
        }
        if let loaded = values.isLoaded, self.isLoaded != loaded {
            self.isLoaded = loaded
            changed = true
        }

        return changed
    }
}

nonisolated extension Array<Cue> {
    /// Applies a whole batch of replies in one traversal, rather than one
    /// search of the tree per cue. Returns the IDs whose values changed.
    @discardableResult
    mutating func applyValues(_ valuesByID: [String: QLabCueValues]) -> Set<String> {
        var changed = Set<String>()
        guard !valuesByID.isEmpty else { return changed }

        func visit(_ cues: inout [Cue]) {
            for index in cues.indices {
                if let values = valuesByID[cues[index].uniqueID],
                   cues[index].apply(values) {
                    changed.insert(cues[index].uniqueID)
                }
                visit(&cues[index].children)
            }
        }

        visit(&self)
        return changed
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
