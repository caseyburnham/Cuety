import Foundation
import Testing

@testable import Cuety

/// The JSON contract with QLab: reply envelopes and cue payloads.
@Suite("QLab replies")
struct QLabReplyTests {

    /// Wraps a JSON body the way QLab does: one string argument on a
    /// `/reply/…` address.
    private func replyMessage(address: String, json: String) -> OSCMessage {
        OSCMessage("/reply" + address, [.string(json)])
    }

    // MARK: - Envelope

    @Test("Decodes an ok reply with a string payload")
    func decodesStringPayload() throws {
        let message = replyMessage(
            address: "/workspace/ABC/connect",
            json: #"{"workspace_id":"ABC","address":"/workspace/ABC/connect","status":"ok","data":"ok"}"#
        )

        let reply = try QLabReplyParser.parse(message, as: String.self)
        #expect(reply.status == .ok)
        #expect(reply.status.isSuccess)
        #expect(reply.workspaceID == "ABC")
        #expect(reply.address == "/workspace/ABC/connect")
        #expect(reply.data == "ok")
    }

    // MARK: - Correlation keys

    @Test(
        "Strips the workspace prefix when building a correlation key",
        arguments: [
            ("/workspace/ABC/cueLists", "/cueLists"),
            ("/cueLists", "/cueLists"),
            ("/workspace/ABC/cue_id/XYZ/playbackPositionId", "/cue_id/XYZ/playbackPositionId"),
            ("/cue_id/XYZ/playbackPositionId", "/cue_id/XYZ/playbackPositionId"),
            // Not a workspace address, so it must survive untouched.
            ("/workspaces", "/workspaces"),
            ("/workspace/ABC", "/workspace/ABC"),
        ]
    )
    func buildsCorrelationKey(address: String, expected: String) {
        #expect(QLabReplyParser.correlationKey(for: address) == expected)
    }

    @Test("A prefixed request matches a reply that drops the prefix, and vice versa")
    func correlationSurvivesPrefixMismatch() {
        let sent = "/workspace/ABC/cue_id/XYZ/playbackPositionId"
        let echoedWithout = "/cue_id/XYZ/playbackPositionId"

        #expect(
            QLabReplyParser.correlationKey(for: sent)
                == QLabReplyParser.correlationKey(for: echoedWithout)
        )
        // Two different cues must still not collide.
        #expect(
            QLabReplyParser.correlationKey(for: sent)
                != QLabReplyParser.correlationKey(for: "/cue_id/OTHER/playbackPositionId")
        )
    }

    // MARK: - Connect access levels

    @Test(
        "Reads the access level from a connect reply",
        arguments: [
            ("ok", QLabAccessLevel.unspecified),
            ("ok:view", .view),
            ("ok:control", .control),
            ("ok:edit", .edit),
            // A tier added by a later QLab must connect, not be rejected.
            ("ok:supervise", .other("supervise")),
            // A trailing colon is still an acceptance, just an unnamed level.
            ("ok:", .other("")),
        ]
    )
    func readsAccessLevel(data: String, expected: QLabAccessLevel) {
        #expect(QLabAccessLevel(connectReplyData: data) == expected)
    }

    @Test(
        "Rejects connect replies that are not acceptances",
        arguments: ["badpass", "denied", "", "okay", "ok extra", "notok:view"]
    )
    func rejectsNonAcceptances(data: String) {
        #expect(QLabAccessLevel(connectReplyData: data) == nil)
    }

    @Test("Decodes a badpass reply")
    func decodesBadPass() throws {
        let message = replyMessage(
            address: "/workspace/ABC/connect",
            json: #"{"workspace_id":"ABC","address":"/workspace/ABC/connect","status":"ok","data":"badpass"}"#
        )

        let reply = try QLabReplyParser.parse(message, as: String.self)
        #expect(reply.data == "badpass")
    }

    /// `denied` means either "not connected yet" or "this passcode lacks the
    /// privilege", and must not be mistaken for success.
    @Test("Decodes a denied reply")
    func decodesDenied() throws {
        let message = replyMessage(
            address: "/workspace/ABC/go",
            json: #"{"address":"/workspace/ABC/go","status":"denied"}"#
        )

        let reply = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        #expect(reply.status == .denied)
        #expect(!reply.status.isSuccess)
        #expect(reply.workspaceID == nil)
    }

    @Test("Decodes an error reply")
    func decodesError() throws {
        let message = replyMessage(
            address: "/workspace/ABC/cue/999/start",
            json: #"{"address":"/workspace/ABC/cue/999/start","status":"error"}"#
        )

        let reply = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        #expect(reply.status == .error)
    }

    /// An unrecognised status must round-trip rather than being coerced to
    /// success, so a future QLab can't accidentally look healthy.
    @Test("Preserves an unknown status")
    func preservesUnknownStatus() throws {
        let message = replyMessage(
            address: "/workspace/ABC/thump",
            json: #"{"address":"/workspace/ABC/thump","status":"whoknows"}"#
        )

        let reply = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        #expect(reply.status == .unknown("whoknows"))
        #expect(!reply.status.isSuccess)
    }

    // MARK: - Workspaces

    @Test("Decodes the /workspaces payload")
    func decodesWorkspaces() throws {
        let json = """
        {"address":"/workspaces","status":"ok","data":[
          {"uniqueID":"AAA","displayName":"Act One","port":53000,"udpReplyPort":53001,"version":"5.4.6"},
          {"uniqueID":"BBB","displayName":"Act Two","port":53100,"udpReplyPort":53101,"version":"5.4.6"}
        ]}
        """
        let message = replyMessage(address: "/workspaces", json: json)

        let reply = try QLabReplyParser.parse(message, as: [QLabWorkspaceInfo].self)
        let workspaces = try #require(reply.data)
        #expect(workspaces.count == 2)
        #expect(workspaces[0].displayName == "Act One")
        #expect(workspaces[0].port == 53000)
        #expect(workspaces[1].uniqueID == "BBB")
        #expect(workspaces[0].version == "5.4.6")
    }

    /// Older or partial QLab builds omit fields; absent must not be fatal.
    @Test("Tolerates a workspace payload missing optional fields")
    func tolerantWorkspaceDecoding() throws {
        let json = #"{"address":"/workspaces","status":"ok","data":[{"uniqueID":"AAA","displayName":"Show"}]}"#
        let message = replyMessage(address: "/workspaces", json: json)

        let reply = try QLabReplyParser.parse(message, as: [QLabWorkspaceInfo].self)
        let workspace = try #require(reply.data?.first)
        #expect(workspace.port == nil)
        #expect(workspace.version == nil)
    }

    // MARK: - Cue lists

    /// A cue-list payload spelling `listName` the way QLab actually does.
    ///
    /// `listName` is the cue's *own displayed name* in the list, not the name
    /// of the list containing it. The fixture used to set it to "Main Cue
    /// List" on every cue, which is what let the Cue List pill read it as the
    /// containing list and still pass its tests.
    ///
    /// `cue-3` is the interesting one: an audio cue the operator never named,
    /// so QLab supplies the file as its display name.
    private static let cueListsJSON = """
    {"address":"/workspace/ABC/cueLists","status":"ok","data":[
      {"uniqueID":"list-1","name":"Main Cue List","type":"Cue List","cues":[
        {"uniqueID":"cue-1","number":"1","name":"House to Half","type":"Light",
         "listName":"House to Half","colorName":"none","flagged":false,"armed":true},
        {"uniqueID":"grp-1","number":"2","name":"Storm","type":"Group",
         "listName":"Storm","flagged":true,"armed":true,"cues":[
           {"uniqueID":"cue-2","number":"2.1","name":"Thunder","type":"Audio",
            "listName":"Thunder","armed":true}
         ]},
        {"uniqueID":"cue-3","number":"3","name":"","type":"Audio",
         "listName":"rain-loop.wav","armed":true}
      ]},
      {"uniqueID":"list-2","name":"Effects","type":"Cue List","cues":[
        {"uniqueID":"cue-4","number":"90","name":"Panic","type":"Stop",
         "listName":"Panic","armed":true}
      ]}
    ]}
    """

    @Test("Decodes nested cue lists")
    func decodesCueLists() throws {
        let message = replyMessage(
            address: "/workspace/ABC/cueLists", json: Self.cueListsJSON
        )

        let reply = try QLabReplyParser.parse(message, as: [Cue].self)
        let lists = try #require(reply.data)

        #expect(lists.count == 2)
        let list = lists[0]
        #expect(list.name == "Main Cue List")
        #expect(list.children.count == 3)

        let first = list.children[0]
        #expect(first.number == "1")
        #expect(first.name == "House to Half")
        #expect(first.isArmed == true)
        #expect(first.isFlagged == false)
        #expect(first.children.isEmpty)

        let group = list.children[1]
        #expect(group.isGroup)
        #expect(group.isFlagged == true)
        #expect(group.children.count == 1)
        #expect(group.children[0].number == "2.1")
    }

    @Test("The containing cue list comes from the tree, not from listName")
    func containingCueListIsDerivedFromTheTree() throws {
        let message = replyMessage(
            address: "/workspace/ABC/cueLists", json: Self.cueListsJSON
        )
        let lists = try #require(QLabReplyParser.parse(message, as: [Cue].self).data)

        // A top-level cue, a cue nested inside a group, and a cue in a second
        // list. Under the old interpretation the first two would both have
        // reported "House to Half" and "Thunder" as their cue lists.
        #expect(lists.cueList(containing: "cue-1")?.displayName == "Main Cue List")
        #expect(lists.cueList(containing: "cue-2")?.displayName == "Main Cue List")
        #expect(lists.cueList(containing: "cue-4")?.displayName == "Effects")

        // The group reports the list, not itself.
        #expect(lists.cueList(containing: "grp-1")?.uniqueID == "list-1")

        // A cue QLab has never heard of belongs to no list, rather than
        // silently defaulting to one.
        #expect(lists.cueList(containing: "nope") == nil)
    }

    @Test("An unnamed cue falls back to the name QLab displays for it")
    func unnamedCueUsesQLabDisplayName() throws {
        let message = replyMessage(
            address: "/workspace/ABC/cueLists", json: Self.cueListsJSON
        )
        let lists = try #require(QLabReplyParser.parse(message, as: [Cue].self).data)
        let named = try #require(lists.firstCue(withID: "cue-1"))
        let unnamed = try #require(lists.firstCue(withID: "cue-3"))

        // The operator's own name always wins.
        #expect(named.displayName == "House to Half")
        // With no name of their own, QLab's display name beats "Untitled".
        #expect(unnamed.name?.isEmpty == true)
        #expect(unnamed.displayName == "rain-loop.wav")
    }

    /// Unnumbered cues are legal in QLab, and the display has to cope.
    @Test("Handles a cue with no number")
    func handlesUnnumberedCue() throws {
        let json = #"{"address":"/x","status":"ok","data":[{"uniqueID":"c","name":"Untitled"}]}"#
        let message = replyMessage(address: "/x", json: json)

        let cue = try #require(
            try QLabReplyParser.parse(message, as: [Cue].self).data?.first
        )
        #expect(cue.displayNumber == nil)
        #expect(cue.displayName == "Untitled")
    }

    /// A number that is present but whitespace is as good as absent, and must
    /// not render as a blank headline.
    @Test("Treats a whitespace-only number as absent")
    func whitespaceNumberIsAbsent() throws {
        let json = #"{"address":"/x","status":"ok","data":[{"uniqueID":"c","number":"   "}]}"#
        let message = replyMessage(address: "/x", json: json)

        let cue = try #require(
            try QLabReplyParser.parse(message, as: [Cue].self).data?.first
        )
        #expect(cue.displayNumber == nil)
    }

    // MARK: - valuesForKeys

    @Test("Decodes and merges valuesForKeys into a nested cue")
    func mergesValuesForKeys() throws {
        let json = """
        {"address":"/workspace/ABC/cue_id/cue-2/valuesForKeys","status":"ok",
         "data":{"duration":4.25,"preWait":1.5,"postWait":0,"continueMode":1,"notes":"Cue the rain"}}
        """
        let message = replyMessage(
            address: "/workspace/ABC/cue_id/cue-2/valuesForKeys", json: json
        )

        let values = try #require(
            try QLabReplyParser.parse(message, as: QLabCueValues.self).data
        )
        #expect(values.duration == 4.25)
        #expect(values.continueMode == 1)

        // Merge into a tree, targeting a cue nested inside a group.
        var lists: [Cue] = {
            var group = Cue(uniqueID: "grp-1")
            group.children = [Cue(uniqueID: "cue-2")]
            var list = Cue(uniqueID: "list-1")
            list.children = [group]
            return [list]
        }()

        // The mutating call happens outside `#expect`: the macro captures its
        // operand immutably.
        let didMerge = lists.applyValues(values, toCueWithID: "cue-2")
        #expect(didMerge)

        let merged = lists.firstCue(withID: "cue-2")
        let updated = try #require(merged)
        #expect(updated.duration == 4.25)
        #expect(updated.preWait == 1.5)
        #expect(updated.continueMode == .autoContinue)
        #expect(updated.notes == "Cue the rain")
    }

    @Test("Reports when the merge target is not in the tree")
    func mergeMissesUnknownCue() {
        var lists = [Cue(uniqueID: "list-1")]
        let values = QLabCueValues(
            notes: nil, duration: 1, preWait: nil, postWait: nil, continueMode: nil
        )
        let didMerge = lists.applyValues(values, toCueWithID: "nope")
        #expect(!didMerge)
    }

    // MARK: - Correlation

    /// Correlation runs off the echoed `address` field, because the `/reply/…`
    /// OSC address sometimes drops the workspace prefix.
    @Test("Correlates on the echoed address field")
    func correlatesOnEchoedAddress() {
        let message = replyMessage(
            address: "/cueLists",
            json: #"{"address":"/workspace/ABC/cueLists","status":"ok"}"#
        )
        #expect(QLabReplyParser.correlationAddress(of: message) == "/workspace/ABC/cueLists")
    }

    /// When the body is unreadable, fall back to the OSC address so the request
    /// still fails fast instead of waiting for its timeout.
    @Test("Falls back to the OSC address when the body is unreadable")
    func fallsBackToOSCAddress() {
        let message = OSCMessage("/reply/workspace/ABC/thump", [.string("not json at all")])
        #expect(QLabReplyParser.correlationAddress(of: message) == "/workspace/ABC/thump")
    }

    @Test("Recognises reply addresses")
    func recognisesReplies() {
        #expect(QLabReplyParser.isReply(OSCMessage("/reply/workspaces")))
        #expect(!QLabReplyParser.isReply(OSCMessage("/update/workspace/ABC")))
        #expect(!QLabReplyParser.isReply(OSCMessage("/workspace/ABC/thump")))
    }

    // MARK: - Failure modes

    @Test("Rejects a non-reply message")
    func rejectsNonReply() {
        #expect(throws: QLabReplyParser.Failure.self) {
            _ = try QLabReplyParser.parse(
                OSCMessage("/update/workspace/ABC"), as: QLabEmptyPayload.self
            )
        }
    }

    @Test("Rejects a reply with no JSON argument")
    func rejectsMissingArgument() {
        #expect(throws: QLabReplyParser.Failure.self) {
            _ = try QLabReplyParser.parse(
                OSCMessage("/reply/workspaces"), as: QLabEmptyPayload.self
            )
        }
    }

    @Test("Rejects a reply whose JSON is malformed")
    func rejectsMalformedJSON() {
        let message = replyMessage(address: "/workspaces", json: "{ this is not json")

        #expect(throws: QLabReplyParser.Failure.self) {
            _ = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        }
    }

    /// A payload of the wrong shape must fail the one request, with a readable
    /// reason for the inspector — not crash and not silently return nil.
    @Test("Rejects a payload of the wrong shape")
    func rejectsWrongShapePayload() throws {
        let message = replyMessage(
            address: "/workspaces",
            json: #"{"address":"/workspaces","status":"ok","data":"not-an-array"}"#
        )

        let error = try #require(throws: QLabReplyParser.Failure.self) {
            _ = try QLabReplyParser.parse(message, as: [QLabWorkspaceInfo].self)
        }
        #expect(!error.description.isEmpty)
    }
}
