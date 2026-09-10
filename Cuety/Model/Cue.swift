import SwiftUI

/// A QLab workspace as reported by `/workspaces`.
nonisolated struct QLabWorkspaceInfo: Decodable, Hashable, Sendable, Identifiable {
    let uniqueID: String
    let displayName: String
    let port: Int?
    let udpReplyPort: Int?
    let version: String?
    /// QLab reports this on some builds; absent means "unknown", not "no passcode".
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

/// A cue, as reported by `/cueLists` and refined by `valuesForKeys`.
///
/// Only `uniqueID` is required. Everything else is optional because QLab omits
/// keys that don't apply to a cue type, and because an absent value is
/// meaningful in this app: a pill that isn't there tells the operator something.
nonisolated struct Cue: Hashable, Sendable, Identifiable {
    let uniqueID: String

    /// The cue number. Optional — unnumbered cues are legal and common.
    var number: String?

    /// The name the operator typed, empty for a cue they never named.
    var name: String?

    /// The name QLab *displays* for this cue in its cue list.
    ///
    /// Not the name of the containing cue list, despite how it reads. QLab
    /// fills this in for a cue with no name of its own — an audio cue shows
    /// its file, a group shows its type — so it is the closest thing to "what
    /// QLab calls this cue" and nothing more. Ask
    /// ``Swift/Array/cueList(containing:)`` for the list a cue belongs to.
    var listName: String?

    /// QLab's cue type string, e.g. `"Audio"`, `"Group"`, `"Light"`.
    var type: String?
    var colorName: String?
    var isFlagged: Bool?
    var isArmed: Bool?

    /// Populated lazily by `valuesForKeys` for the cue at the playhead only.
    var notes: String?
    var duration: TimeInterval?
    var preWait: TimeInterval?
    var postWait: TimeInterval?
    var continueMode: ContinueMode?

    /// Child cues, for groups and cue lists.
    var children: [Cue] = []

    var id: String { uniqueID }

    init(uniqueID: String) {
        self.uniqueID = uniqueID
    }

    /// Whether this cue is a container rather than an action.
    var isGroup: Bool { !children.isEmpty || type?.caseInsensitiveCompare("group") == .orderedSame }

    /// What to show as the headline when there is no cue number.
    var displayNumber: String? {
        guard let number, !number.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return number
    }

    /// What to call this cue on screen.
    ///
    /// The operator's own ``name`` wins wherever they gave one. Failing that,
    /// QLab's ``listName`` — the name it displays for an unnamed cue, such as
    /// the audio file it plays — because that is the label the operator
    /// already recognises from QLab's own window. Only when neither exists is
    /// the cue genuinely nameless, and callers fall back to a placeholder or
    /// promote the number instead.
    var displayName: String? {
        Self.trimmedNonEmpty(name) ?? Self.trimmedNonEmpty(listName)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// The colour the operator gave this cue in QLab, or `nil` when they gave
    /// it none.
    ///
    /// Mapped onto the system colours rather than sampled from QLab's own
    /// palette: those are fixed sRGB values, while these adapt to light and
    /// dark appearance and to Increase Contrast. A booth display has to stay
    /// legible before it has to match QLab's inspector pixel for pixel.
    ///
    /// An unrecognised name — a colour a later QLab adds — also returns `nil`,
    /// so the cue falls back to the standard text style instead of being
    /// assigned a colour nobody chose.
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

/// QLab's continue mode, which governs what happens after a cue fires.
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
        case .autoContinue: "arrow.turn.down.right"
        case .autoFollow: "arrow.right.to.line"
        }
    }
}

/// The subset of cue properties Cuety fetches with `valuesForKeys`.
///
/// Separate from ``Cue`` because these arrive later and only for the cue at the
/// playhead — folding them into the main decoder would imply they're always
/// present.
nonisolated struct QLabCueValues: Decodable, Sendable {
    var notes: String?
    var duration: Double?
    var preWait: Double?
    var postWait: Double?
    var continueMode: Int?
}

nonisolated extension Cue {
    /// Merges fetched detail values into this cue.
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
    /// Applies detail values to the cue with the given ID, searching nested
    /// groups depth-first.
    ///
    /// - Returns: `true` if the cue was found and updated.
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

    /// Finds a cue by ID, searching nested groups depth-first.
    func firstCue(withID cueID: String) -> Cue? {
        for cue in self {
            if cue.uniqueID == cueID { return cue }
            if let found = cue.children.firstCue(withID: cueID) { return found }
        }
        return nil
    }

    /// The cue list containing `cueID`, given the array of cue lists QLab
    /// returned from `/cueLists`.
    ///
    /// Derived from the tree, because nothing on a ``Cue`` records it:
    /// ``Cue/listName`` is the cue's own displayed name, so reading it as the
    /// containing list's name put the cue's name in the "Cue List" pill and
    /// was wrong for every cue that had a name at all. A group's children are
    /// searched too, so a nested cue reports the list rather than the group.
    func cueList(containing cueID: String) -> Cue? {
        first { $0.children.firstCue(withID: cueID) != nil }
    }
}

// MARK: - Decoding from /cueLists

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
        // QLab nests children under `cues`. Absent for non-containers.
        children = try container.decodeIfPresent([Cue].self, forKey: .cues) ?? []
    }
}
