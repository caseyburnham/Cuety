import Testing

@testable import Cuety

@Suite("Cue states")
@MainActor
struct CueStateTests {
    private var everyState: Cue {
        var cue = Cue(uniqueID: "C")
        cue.isBroken = true
        cue.isArmed = false
        cue.isLoaded = true
        cue.isFlagged = true
        cue.continueMode = .autoFollow
        return cue
    }

    @Test("A cue in no special state has none to show")
    func plainCueHasNoStates() {
        var cue = Cue(uniqueID: "C")
        cue.isArmed = true
        cue.continueMode = .doNotContinue
        #expect(CueState.states(of: cue).isEmpty)
        #expect(CueIndicators.accessibilityParts(for: cue).isEmpty)
    }

    @Test("States keep the drawer's order and are spoken in it")
    func statesAreOrdered() {
        #expect(CueState.states(of: everyState).map(\.kind) == CueState.kinds)
        #expect(CueIndicators.accessibilityParts(for: everyState) == [
            "broken", "disarmed, will be skipped", "loaded", "flagged", "Auto-Follow",
        ])
    }

    @Test("A pill and a drawer glyph describe a state the same way")
    func pillsMatchIndicators() throws {
        for state in CueState.states(of: everyState) {
            let pill = try #require(DetailPill.content(for: state.kind, cue: everyState, cueListName: nil))
            #expect(pill.text == state.title)
            #expect(pill.systemImage == state.systemImage)
            #expect(pill.help == state.help)
            #expect(pill.glyphRotation == state.rotation)
        }
    }
}
