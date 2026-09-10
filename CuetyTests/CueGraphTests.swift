import Foundation
import Testing

@testable import Cuety

/// What the drawer is allowed to say about a cue list.
///
/// Two contracts are under test. A group is *one row* and its children are not
/// rows — but they are still indexed, because the playhead can be parked on
/// one of them and the display has to be able to name it.
@Suite("Cue graph")
struct CueGraphTests {
    private func cue(_ id: String, _ name: String, children: [Cue] = []) -> Cue {
        var cue = Cue(uniqueID: id)
        cue.number = id
        cue.name = name
        cue.children = children
        return cue
    }

    /// `1`, `2` (a group of `2.1`, `2.2` — the second itself a group of
    /// `2.2.1`), `3`, `4`. Four rows; eight cues.
    private func showList() -> Cue {
        cue("list", "Main", children: [
            cue("1", "House to Half"),
            cue("2", "Storm", children: [
                cue("2.1", "Thunder"),
                cue("2.2", "Rain", children: [
                    cue("2.2.1", "Drips"),
                ]),
            ]),
            cue("3", "House Out"),
            cue("4", "Curtain"),
        ])
    }

    @Test("A group is one row and its children are not rows")
    func groupsCollapseToOneRow() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.rows.map(\.uniqueID) == ["1", "2", "3", "4"])
    }

    @Test("Neighbouring rows skip whatever is inside a group")
    func neighboursAreRows() {
        let graph = CueGraph(cueList: showList())

        // Not "2.2.1", "2.2", "2.1" — the group's contents are not rows, so
        // the row above `3` is the group itself.
        #expect(graph.rowsAbove("3", count: 2).map(\.uniqueID) == ["1", "2"])
        #expect(graph.rowsBelow("1", count: 2).map(\.uniqueID) == ["2", "3"])
    }

    @Test("Children are still findable even though they are not drawn")
    func nestedCuesRemainIndexed() {
        let graph = CueGraph(cueList: showList())

        // The playhead can sit on any of these, and the display names the cue
        // itself rather than the group standing in for it.
        #expect(graph.cue(withID: "2.1")?.displayName == "Thunder")
        #expect(graph.cue(withID: "2.2.1")?.displayName == "Drips")
        #expect(graph.cue(withID: "nope") == nil)
    }

    @Test("A playhead inside a group is positioned against the group's row")
    func nestedPlayheadUsesItsGroupsRow() {
        let graph = CueGraph(cueList: showList())

        // Whether the playhead is on `2`, `2.1` or the doubly-nested `2.2.1`,
        // the drawer shows the same neighbourhood — otherwise stepping into a
        // group would blank it.
        for cueID in ["2", "2.1", "2.2", "2.2.1"] {
            #expect(graph.rowsAbove(cueID, count: 3).map(\.uniqueID) == ["1"])
            #expect(graph.rowsBelow(cueID, count: 3).map(\.uniqueID) == ["3", "4"])
        }
    }

    @Test("The containing group is reported only for cues that are not rows")
    func containingRowNamesTheGroup() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.containingRow(of: "2.1")?.uniqueID == "2")
        // Nested two deep, and it still reports the outermost row rather than
        // the immediate parent: that is the row on screen.
        #expect(graph.containingRow(of: "2.2.1")?.uniqueID == "2")

        // A row is not inside anything, and neither is a cue this list has
        // never heard of.
        #expect(graph.containingRow(of: "2") == nil)
        #expect(graph.containingRow(of: "1") == nil)
        #expect(graph.containingRow(of: "nope") == nil)
    }

    /// The display prints "End of List" from `isLast`, so a false positive
    /// here is a claim on screen that the show is over.
    @Test("Boundaries are claimed only for the first and last rows")
    func boundariesAreStrict() {
        let graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("1", "Opening", children: [cue("1.1", "Inside opening")]),
            cue("2", "Finale", children: [cue("2.1", "Inside finale")]),
        ]))

        #expect(graph.isFirst("1"))
        #expect(graph.isLast("2"))

        // A cue inside the first group has a group cue above it that the
        // drawer is showing, so it is not the top of the cue list. A cue
        // inside the last group has cues after it inside that group, so the
        // list has not ended.
        #expect(!graph.isFirst("1.1"))
        #expect(!graph.isLast("2.1"))
    }

    @Test("A list with no cues has no rows and claims no boundaries")
    func emptyList() {
        let graph = CueGraph(cueList: cue("list", "Main"))

        #expect(graph.rows.isEmpty)
        #expect(graph.rowsAbove("anything", count: 3).isEmpty)
        #expect(graph.rowsBelow("anything", count: 3).isEmpty)
        #expect(!graph.isFirst("anything"))
        #expect(!graph.isLast("anything"))
    }

    @Test("Asking for no rows returns none rather than the whole list")
    func zeroCountReturnsNothing() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.rowsAbove("3", count: 0).isEmpty)
        #expect(graph.rowsBelow("1", count: 0).isEmpty)
    }

    @Test("Fewer rows than asked for are returned near the ends of the list")
    func neighbourhoodsClampToTheList() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.rowsAbove("1", count: 5).isEmpty)
        #expect(graph.rowsAbove("2", count: 5).map(\.uniqueID) == ["1"])
        #expect(graph.rowsBelow("4", count: 5).isEmpty)
        #expect(graph.rowsBelow("3", count: 5).map(\.uniqueID) == ["4"])
    }
}
