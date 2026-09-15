import CoreGraphics
import Foundation
import Testing

@testable import Cuety

/// How large the cue number is drawn, and why it is the same size for every cue
/// in a list.
///
/// The display used to set the number at a huge base size and let
/// `minimumScaleFactor` fit it, which fits *the string that is there*: cue `5`
/// came out near full height and cue `127.5` a third of it, so the headline
/// changed size on every GO. Sizing to a reference number instead is what these
/// tests hold in place.
@Suite("Cue number sizing")
@MainActor
struct CueNumberSizingTests {
    private func typography() throws -> Typography {
        Typography(
            preferences: Preferences(
                defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
            )
        )
    }

    private let space = CGSize(width: 1_200, height: 600)

    /// The failure this whole change exists to prevent.
    @Test("A short number is no longer drawn larger than a long one")
    func shortNumbersDoNotGetTheirOwnSize() throws {
        let typography = try typography()

        // Fitting each number to itself is what used to happen, and it is
        // still what happens if a caller passes the displayed number as its
        // own reference.
        let fittedToItself = typography.cueNumberPointSize(fitting: "1", in: space)
        let fittedToTheList = typography.cueNumberPointSize(fitting: "127.5", in: space)

        #expect(fittedToItself > fittedToTheList)
    }

    @Test("The widest number in the list is the one chosen as the reference")
    func widestNumberWins() throws {
        let typography = try typography()

        #expect(typography.widestCueNumber(among: ["1", "127.5", "12"]) == "127.5")
        // More characters is not the same as wider: dots are narrow.
        #expect(typography.widestCueNumber(among: ["1.1.1", "9999"]) == "9999")
        #expect(typography.widestCueNumber(among: []) == nil)
    }

    @Test("The fitted size fills the space without overflowing it")
    func fittedSizeFitsTheSpace() throws {
        let typography = try typography()
        let size = typography.cueNumberPointSize(fitting: "127.5", in: space)

        // A point size is not a drawn width, so this checks the bounds rather
        // than an exact value: too small to read, or taller than the space it
        // was given, are both the bug.
        #expect(size > Typography.cueNumberMinimumSize)
        #expect(size <= space.height)
    }

    @Test("A space with no room to draw in still yields a usable size")
    func degenerateSpacesAreHandled() throws {
        let typography = try typography()

        // Both happen for a frame during window setup, and neither may produce
        // a NaN or a negative font size.
        #expect(typography.cueNumberPointSize(fitting: "1", in: .zero)
            == Typography.cueNumberMinimumSize)
        #expect(typography.cueNumberPointSize(fitting: "", in: space)
            == Typography.cueNumberMinimumSize)
    }

    @Test("The size never exceeds the ceiling, however much space there is")
    func hugeSpacesAreCapped() throws {
        let typography = try typography()
        let size = typography.cueNumberPointSize(
            fitting: "1", in: CGSize(width: 100_000, height: 100_000)
        )

        #expect(size == Typography.cueNumberBaseSize)
    }
}
