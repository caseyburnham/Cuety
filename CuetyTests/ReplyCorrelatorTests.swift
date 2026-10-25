import Foundation
import Testing

@testable import Cuety

@Suite("Reply correlation")
struct ReplyCorrelatorTests {
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
}
