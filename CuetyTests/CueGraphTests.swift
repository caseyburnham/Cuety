import Foundation
import Testing

@testable import Cuety

@Suite("Cue graph")
struct CueGraphTests {
    private func cue(_ id: String, _ name: String, children: [Cue] = []) -> Cue {
        var cue = Cue(uniqueID: id)
        cue.number = id
        cue.name = name
        cue.children = children
        return cue
    }

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

        #expect(graph.rowIDs == ["1", "2", "3", "4"])
    }

    @Test("Neighbouring rows skip whatever is inside a group")
    func neighboursAreRows() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.rowsAbove("3", count: 2) == ["1", "2"])
        #expect(graph.rowsBelow("1", count: 2) == ["2", "3"])
    }

    @Test("Children are still findable even though they are not drawn")
    func nestedCuesRemainIndexed() {
        let list = showList()
        let graph = CueGraph(cueList: list)

        #expect(graph.cue(withID: "2.1", in: list)?.displayName == "Thunder")
        #expect(graph.cue(withID: "2.2.1", in: list)?.displayName == "Drips")
        #expect(graph.cue(withID: "nope", in: list) == nil)
    }

    @Test("Stale and unwatched cue paths resolve against the current tree")
    func valueUpdatesFindCuesAfterTheirPathsChange() throws {
        var graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("target", "Target"),
        ]))
        var currentLists = [
            cue("other", "Other", children: [cue("offwatch", "Off watch")]),
            cue("list", "Main", children: [
                cue("first", "First"),
                cue("group", "Group", children: [cue("target", "Target")]),
            ]),
        ]
        let values = try JSONDecoder().decode(
            QLabCueValues.self,
            from: Data(#"{"number":"7","duration":42}"#.utf8)
        )

        let changes = currentLists.applyValuesAndFindCues(
            ["target": values, "offwatch": values], using: graph
        )

        #expect(changes.foundCueIDs == Set(["target", "offwatch"]))
        #expect(changes.changedCueIDs == Set(["target", "offwatch"]))
        #expect(currentLists.firstCue(withID: "target")?.displayNumber == "7")
        #expect(currentLists.firstCue(withID: "target")?.duration == 42)
        #expect(currentLists.firstCue(withID: "offwatch")?.duration == 42)

        graph.applyCueNumberUpdates(changes.cueNumberUpdates)
        #expect(graph.cueNumbers == ["7"])

        let identical = currentLists.applyValuesAndFindCues(
            ["target": values, "offwatch": values], using: graph
        )
        #expect(identical.foundCueIDs == Set(["target", "offwatch"]))
        #expect(identical.changedCueIDs.isEmpty)
    }

    @Test("A playhead inside a group is positioned against the group's row")
    func nestedPlayheadUsesItsGroupsRow() {
        let graph = CueGraph(cueList: showList())

        for cueID in ["2", "2.1", "2.2", "2.2.1"] {
            #expect(graph.rowsAbove(cueID, count: 3) == ["1"])
            #expect(graph.rowsBelow(cueID, count: 3) == ["3", "4"])
        }
    }

    @Test("The containing group is reported only for cues that are not rows")
    func containingRowNamesTheGroup() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.containingRowID(of: "2.1") == "2")
        #expect(graph.containingRowID(of: "2.2.1") == "2")

        #expect(graph.containingRowID(of: "2") == nil)
        #expect(graph.containingRowID(of: "1") == nil)
        #expect(graph.containingRowID(of: "nope") == nil)
    }

    @Test("Boundaries are claimed only for the first and last rows")
    func boundariesAreStrict() {
        let graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("1", "Opening", children: [cue("1.1", "Inside opening")]),
            cue("2", "Finale", children: [cue("2.1", "Inside finale")]),
        ]))

        #expect(graph.isFirst("1"))
        #expect(graph.isLast("2"))

        #expect(!graph.isFirst("1.1"))
        #expect(!graph.isLast("2.1"))
    }

    @Test("A list with no cues has no rows and claims no boundaries")
    func emptyList() {
        let graph = CueGraph(cueList: cue("list", "Main"))

        #expect(graph.rowIDs.isEmpty)
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
        #expect(graph.rowsAbove("2", count: 5) == ["1"])
        #expect(graph.rowsBelow("4", count: 5).isEmpty)
        #expect(graph.rowsBelow("3", count: 5) == ["4"])
    }

    private func longList() -> Cue {
        cue("list", "Main", children: (1...6).map { cue("\($0)", "Cue \($0)") })
    }

    @Test("Rows the end of the list cannot supply are shown above instead")
    func shortfallBelowIsSpentAbove() {
        let graph = CueGraph(cueList: longList())

        let nearEnd = graph.neighbourhood(around: "5", above: 3, below: 3)
        #expect(nearEnd.above == ["1", "2", "3", "4"])
        #expect(nearEnd.below == ["6"])

        let atEnd = graph.neighbourhood(around: "6", above: 3, below: 3)
        #expect(atEnd.above == ["1", "2", "3", "4", "5"])
        #expect(atEnd.below.isEmpty)
    }

    @Test("The same applies at the top of the list, in the other direction")
    func shortfallAboveIsSpentBelow() {
        let graph = CueGraph(cueList: longList())

        let atStart = graph.neighbourhood(around: "1", above: 3, below: 3)
        #expect(atStart.above.isEmpty)
        #expect(atStart.below == ["2", "3", "4", "5", "6"])

        let nearStart = graph.neighbourhood(around: "2", above: 3, below: 3)
        #expect(nearStart.above == ["1"])
        #expect(nearStart.below == ["3", "4", "5", "6"])
    }

    @Test("In the middle of a list, both sides get exactly what was asked for")
    func middleOfTheListIsUnchanged() {
        let graph = CueGraph(cueList: longList())

        let middle = graph.neighbourhood(around: "4", above: 3, below: 2)
        #expect(middle.above == ["1", "2", "3"])
        #expect(middle.below == ["5", "6"])
    }

    @Test("A side set to none stays empty, and lends rather than borrows")
    func zeroIsRespectedInBothDirections() {
        let graph = CueGraph(cueList: longList())

        let atEnd = graph.neighbourhood(around: "6", above: 0, below: 3)
        #expect(atEnd.above.isEmpty)
        #expect(atEnd.below.isEmpty)

        let atStart = graph.neighbourhood(around: "1", above: 3, below: 0)
        #expect(atStart.above.isEmpty)
        #expect(atStart.below.isEmpty)
    }

    @Test("A list too short to fill the drawer is not padded")
    func shortListsAreNotPadded() {
        let graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("1", "Opening"), cue("2", "Finale"),
        ]))

        let neighbourhood = graph.neighbourhood(around: "1", above: 3, below: 3)
        #expect(neighbourhood.above.isEmpty)
        #expect(neighbourhood.below == ["2"])
        #expect(neighbourhood.count == 1)
    }

    @Test("A playhead inside a group borrows against the group's row")
    func nestedPlayheadRedistributes() {
        let graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("1", "One"), cue("2", "Two"), cue("3", "Three"),
            cue("4", "Finale", children: [cue("4.1", "Inside finale")]),
        ]))

        let neighbourhood = graph.neighbourhood(around: "4.1", above: 2, below: 2)
        #expect(neighbourhood.above == ["1", "2", "3"])
        #expect(neighbourhood.below.isEmpty)
    }

    @Test("A cue this list has never heard of has no neighbourhood")
    func unknownCueHasNoNeighbourhood() {
        let graph = CueGraph(cueList: longList())

        let neighbourhood = graph.neighbourhood(around: "nope", above: 3, below: 3)
        #expect(neighbourhood.above.isEmpty)
        #expect(neighbourhood.below.isEmpty)
    }

    @Test("Every cue's number is collected, including nested ones")
    func cueNumbersIncludeNestedCues() {
        let graph = CueGraph(cueList: showList())

        #expect(graph.cueNumbers == ["1", "2", "2.1", "2.2", "2.2.1", "3", "4"])
    }

    @Test("Unnumbered cues contribute no number")
    func cueNumbersSkipUnnumberedCues() {
        var unnumbered = Cue(uniqueID: "blank")
        unnumbered.name = "Blackout"
        var blank = Cue(uniqueID: "whitespace")
        blank.number = "  "

        let graph = CueGraph(cueList: cue("list", "Main", children: [
            cue("1", "House to Half"), unnumbered, blank,
        ]))

        #expect(graph.cueNumbers == ["1"])
    }

    @Test("A cue gaining and losing its number keeps the projection in row order")
    func cueNumberGainAndRemovalPreserveOrder() {
        var middleCue = cue("2", "Two")
        middleCue.number = nil
        let graphCueList = cue("list", "Main", children: [
            cue("1", "One"), middleCue, cue("3", "Three"),
        ])
        var graph = CueGraph(cueList: graphCueList)

        #expect(graph.cueNumbers == ["1", "3"])

        graph.applyCueNumberUpdates([
            CueNumberUpdate(cueID: "2", displayNumber: "2"),
        ])
        #expect(graph.cueNumbers == ["1", "2", "3"])

        graph.applyCueNumberUpdates([
            CueNumberUpdate(cueID: "2", displayNumber: nil),
        ])
        #expect(graph.cueNumbers == ["1", "3"])
    }
}
