import Foundation
import Testing

@testable import Cuety

@Suite("Reply correlation")
struct ReplyCorrelatorTests {
    private let start = ContinuousClock.now

    @Test("A reply goes to the request on its key that has waited longest")
    func repliesAreFirstInFirstOut() {
        var replies = ReplyCorrelator<String>()
        let first = UUID(), second = UUID(), other = UUID()
        replies.register(first, key: "/thump", waiter: "first")
        replies.register(other, key: "/cueLists", waiter: "other")
        replies.register(second, key: "/thump", waiter: "second")

        #expect(replies.firstWaiting(forKey: "/thump") == first)
        let removedFirst = replies.remove(first)
        #expect(removedFirst?.waiter == "first")
        #expect(replies.firstWaiting(forKey: "/thump") == second)
        let removedSecond = replies.remove(second)
        #expect(removedSecond?.key == "/thump")
        #expect(replies.firstWaiting(forKey: "/thump") == nil)
        #expect(replies.waitingIDs == [other])
        let removedAgain = replies.remove(first)
        #expect(removedAgain == nil)
    }

    @Test("While an abandoned answer is owed, a reply on its key may be stale")
    func owedAnswersMarkRepliesStale() {
        var replies = ReplyCorrelator<String>()
        replies.recordAbandoned(key: "/cue_id/C1/valuesForKeys", until: start + .seconds(5))

        #expect(replies.mayBeStale(forKey: "/cue_id/C1/valuesForKeys", at: start + .seconds(1)))
        #expect(!replies.mayBeStale(forKey: "/cue_id/C2/valuesForKeys", at: start + .seconds(1)))
        #expect(!replies.mayBeStale(forKey: "/cue_id/C1/valuesForKeys", at: start + .seconds(6)))
    }

    @Test("A late reply with nobody waiting uses up one owed answer")
    func lateRepliesConsumeOneOwedAnswer() {
        var replies = ReplyCorrelator<String>()
        replies.recordAbandoned(key: "/thump", until: start + .seconds(5))
        replies.recordAbandoned(key: "/thump", until: start + .seconds(5))

        let consumed = (0..<3).map { _ in
            replies.consumeOwedReply(forKey: "/thump", at: start + .seconds(1))
        }
        #expect(consumed == [true, true, false])
        #expect(!replies.hasOwedReplies)
    }

    @Test("An answer past its deadline is no longer owed")
    func expiredAnswersArePruned() {
        var replies = ReplyCorrelator<String>()
        replies.recordAbandoned(key: "/thump", until: start + .seconds(1))
        replies.recordAbandoned(key: "/cueLists", until: start + .seconds(10))

        let expired = replies.consumeOwedReply(forKey: "/thump", at: start + .seconds(2))
        #expect(!expired)
        replies.pruneOwedReplies(at: start + .seconds(2))
        #expect(replies.hasOwedReplies)
        #expect(replies.mayBeStale(forKey: "/cueLists", at: start + .seconds(2)))

        replies.pruneOwedReplies(at: start + .seconds(11))
        #expect(!replies.hasOwedReplies)
    }
}
