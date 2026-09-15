import SwiftUI

nonisolated struct QLabWorkspaceInfo: Decodable, Hashable, Sendable, Identifiable {
    let uniqueID: String
    let displayName: String
    let port: Int?
    let udpReplyPort: Int?
    let version: String?
    let hasPasscode: Bool?

    var id: String { uniqueID }

    private enum CodingKeys: String, CodingKey {
        case uniqueID
        case displayName
        case port
        case udpReplyPort
        case version
        case hasPasscode
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

    var children: [Cue] = []

    var id: String { uniqueID }

    init(uniqueID: String) {
        self.uniqueID = uniqueID
    }

    var isGroup: Bool { !children.isEmpty || type?.caseInsensitiveCompare("group") == .orderedSame }

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
        switch colorName?.lowercased() {
        case "red": .red
        case "orange": .orange
        case "green": .green
        case "blue": .blue
        case "purple": .purple
        default: nil
        }
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
    var notes: String?
    var duration: Double?
    var preWait: Double?
    var postWait: Double?
    var continueMode: Int?
}

nonisolated extension Cue {
    var detailValues: QLabCueValues {
        QLabCueValues(
            notes: notes,
            duration: duration,
            preWait: preWait,
            postWait: postWait,
            continueMode: continueMode?.rawValue
        )
    }

    mutating func apply(_ values: QLabCueValues) {
        if let notes = values.notes { self.notes = notes }
        if let duration = values.duration { self.duration = duration }
        if let preWait = values.preWait { self.preWait = preWait }
        if let postWait = values.postWait { self.postWait = postWait }
        if let mode = values.continueMode.flatMap(ContinueMode.init(rawValue:)) {
            self.continueMode = mode
        }
    }
}

nonisolated extension Array<Cue> {
    @discardableResult
    mutating func applyValues(_ values: QLabCueValues, toCueWithID cueID: String) -> Bool {
        for index in indices {
            if self[index].uniqueID == cueID {
                self[index].apply(values)
                return true
            }
            if self[index].children.applyValues(values, toCueWithID: cueID) {
                return true
            }
        }
        return false
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
