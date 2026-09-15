import Foundation
import Testing

@testable import Cuety

@Suite("Activity log redaction")
@MainActor
struct ActivityLogRedactionTests {
    private static let passcode = "hunter2"

    private func connectMessage(workspaceID: String = "ABC") -> OSCMessage {
        OSCMessage("/workspace/\(workspaceID)/connect", [.string(Self.passcode)])
    }

    @Test("A passcode never reaches a retained log entry")
    func passcodeIsNotStored() {
        let event = OSCEvent(
            message: connectMessage(), direction: .outbound, byteCount: 44
        )

        #expect(!event.arguments.contains(Self.passcode))
        #expect(event.arguments.contains(OSCRedaction.placeholder))
        #expect(event.address == "/workspace/ABC/connect")
    }

    @Test("Copied text carries no passcode")
    func copiedTextIsRedacted() {
        let event = OSCEvent(
            message: connectMessage(), direction: .outbound, byteCount: 44
        )

        #expect(!event.copyableDescription.contains(Self.passcode))
        #expect(event.copyableDescription.contains(OSCRedaction.placeholder))
    }

    @Test("The recorded byte count is the packet's, not the placeholder's")
    func byteCountDescribesTheWire() {
        let message = connectMessage()
        let wireSize = OSCEncoder().encode(message).count
        let log = ActivityLog()

        log.record(OSCEvent(message: message, direction: .outbound, byteCount: wireSize))

        #expect(log.bytesSent == wireSize)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].byteCount == wireSize)
    }

    @Test("A passcode is absent from every entry the log holds")
    func logHoldsNoPasscode() {
        let log = ActivityLog()
        log.record(OSCEvent(message: connectMessage(), direction: .outbound, byteCount: 44))
        log.record(OSCEvent(
            message: OSCMessage("/reply/workspace/ABC/connect", [.string(
                #"{"address":"/workspace/ABC/connect","status":"ok","data":"ok:view"}"#
            )]),
            direction: .inbound,
            byteCount: 96
        ))

        for entry in log.entries {
            #expect(!entry.arguments.contains(Self.passcode))
            #expect(!entry.address.contains(Self.passcode))
            #expect(!entry.copyableDescription.contains(Self.passcode))
        }
    }

    @Test("Messages that carry no credential are logged verbatim", arguments: [
        OSCMessage("/workspaces"),
        OSCMessage("/updates", [.true]),
        OSCMessage("/alwaysReply", [.true]),
        OSCMessage("/workspace/ABC/cueLists"),
        OSCMessage("/workspace/ABC/cue_id/XYZ/valuesForKeys", [.string(#"["duration"]"#)]),
        OSCMessage("/workspace/ABC/thump"),
    ])
    func nonCredentialMessagesAreUntouched(message: OSCMessage) {
        #expect(OSCRedaction.redacting(message) == message)
    }

    @Test("A connect message with no arguments is left alone")
    func passcodelessConnectIsUntouched() {
        let message = OSCMessage("/workspace/ABC/connect")

        #expect(OSCRedaction.redacting(message) == message)
        #expect(OSCEvent(message: message, direction: .outbound, byteCount: 32).arguments.isEmpty)
    }

    @Test("Redaction survives extra arguments rather than assuming a position")
    func everyConnectArgumentIsRedacted() {
        let message = OSCMessage(
            "/workspace/ABC/connect", [.string("first"), .string(Self.passcode)]
        )
        let redacted = OSCRedaction.redacting(message)

        #expect(redacted.arguments.count == 2)
        #expect(redacted.arguments.allSatisfy { $0.stringValue == OSCRedaction.placeholder })
    }
}
