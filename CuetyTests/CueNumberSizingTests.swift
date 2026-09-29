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

    @Test("Alphanumeric identifiers are compared by their measured width")
    func alphanumericIdentifiersAreMeasured() throws {
        let typography = try typography()

        #expect(typography.widestCueNumber(among: ["1", "SQ-104", "12.5"]) == "SQ-104")
        #expect(typography.widestCueNumber(among: ["WWW", "111"]) == "WWW")
    }

    @Test("The rounded design is measured as the rounded font, not the default")
    func roundedDesignIsMeasured() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.usesRoundedSystemFont = false
        let standard = Typography(preferences: preferences)
        preferences.usesRoundedSystemFont = true
        let rounded = Typography(preferences: preferences)

        let text = "SQ-104 Alpha"
        #expect(rounded.cueNumberWidth(of: text, size: 100)
            != standard.cueNumberWidth(of: text, size: 100))

        // Fitting at a narrow size still yields a width inside the space.
        let narrow = CGSize(width: 120, height: 400)
        let size = rounded.cueNumberPointSize(fitting: text, in: narrow)
        #expect(rounded.cueNumberWidth(of: text, size: size) <= narrow.width + 0.5)
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

    private func typography(sizing: CueNumberSizing, customSize: Double = 240) throws -> Typography {
        let preferences = Preferences(
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        preferences.cueNumberSizing = sizing
        preferences.customCueNumberSize = customSize
        return Typography(preferences: preferences)
    }

    @Test("Fixed sizing fits the list's widest number, not the standby one")
    func fixedSizingFitsTheReference() throws {
        let typography = try typography(sizing: .fixed)

        #expect(typography.standbyNumberPointSize(for: "1", reference: "127.5", in: space)
            == typography.cueNumberPointSize(fitting: "127.5", in: space))
    }

    @Test("Dynamic sizing fits the standby number alone")
    func dynamicSizingFitsTheNumber() throws {
        let typography = try typography(sizing: .dynamic)

        #expect(typography.standbyNumberPointSize(for: "1", reference: "127.5", in: space)
            == typography.cueNumberPointSize(fitting: "1", in: space))
    }

    @Test("Custom sizing uses the chosen size, shrinking only to fit")
    func customSizingIsCappedByTheSpace() throws {
        let small = try typography(sizing: .custom, customSize: 100)
        #expect(small.standbyNumberPointSize(for: "1", reference: "127.5", in: space) == 100)

        let large = try typography(sizing: .custom, customSize: 720)
        let narrow = CGSize(width: 200, height: 600)
        #expect(large.standbyNumberPointSize(for: "127.5", reference: "127.5", in: narrow)
            == large.cueNumberPointSize(fitting: "127.5", in: narrow))
    }

    @Test("The custom size is kept within its limits")
    func customSizeIsClamped() throws {
        let preferences = Preferences(
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        preferences.customCueNumberSize = 1
        #expect(preferences.customCueNumberSize == Preferences.Limits.cueNumberSize.lowerBound)
        preferences.customCueNumberSize = 10_000
        #expect(preferences.customCueNumberSize == Preferences.Limits.cueNumberSize.upperBound)
    }
}
