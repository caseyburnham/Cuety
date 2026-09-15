import CoreGraphics
import Foundation
import Testing

@testable import Cuety

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

    @Test("A short number is no longer drawn larger than a long one")
    func shortNumbersDoNotGetTheirOwnSize() throws {
        let typography = try typography()

        let fittedToItself = typography.cueNumberPointSize(fitting: "1", in: space)
        let fittedToTheList = typography.cueNumberPointSize(fitting: "127.5", in: space)

        #expect(fittedToItself > fittedToTheList)
    }

    @Test("The widest number in the list is the one chosen as the reference")
    func widestNumberWins() throws {
        let typography = try typography()

        #expect(typography.widestCueNumber(among: ["1", "127.5", "12"]) == "127.5")
        #expect(typography.widestCueNumber(among: ["1.1.1", "9999"]) == "9999")
        #expect(typography.widestCueNumber(among: []) == nil)
    }

    @Test("The fitted size fills the space without overflowing it")
    func fittedSizeFitsTheSpace() throws {
        let typography = try typography()
        let size = typography.cueNumberPointSize(fitting: "127.5", in: space)

        #expect(size > Typography.cueNumberMinimumSize)
        #expect(size <= space.height)
    }

    @Test("A space with no room to draw in still yields a usable size")
    func degenerateSpacesAreHandled() throws {
        let typography = try typography()

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
