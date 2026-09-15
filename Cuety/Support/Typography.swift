import SwiftUI

/// Resolves the user's font choice into concrete `Font` values.
///
/// The cue number is sized to fit, but to fit the *widest number in the cue
/// list* rather than the one currently standing by — see
/// ``cueNumberPointSize(fitting:in:)``. Fitting each number to its own width is
/// what `minimumScaleFactor` does on its own, and it made the headline change
/// size every time the playhead moved between a one-digit cue and a five.
@MainActor
struct Typography {
    /// The largest the cue number is ever set. A ceiling rather than a working
    /// size: the fitted size is what the display actually uses.
    static let cueNumberBaseSize: CGFloat = 720

    /// The floor for the cue number, as a fraction of the base size. Low
    /// enough that a long number like "127.5" still fits a narrow window.
    static let cueNumberMinimumScale: CGFloat = 0.02

    /// The smallest the cue number is ever set.
    static var cueNumberMinimumSize: CGFloat { cueNumberBaseSize * cueNumberMinimumScale }

    /// The point size cue numbers are measured at.
    ///
    /// Text width scales linearly with point size, so a single measurement
    /// here yields the size that fits any given space — no search, and no
    /// repeated measuring as a window resizes.
    static let measuringPointSize: CGFloat = 100

    let usesRounded: Bool

    /// The operator's chosen weight for the cue number.
    ///
    /// Exposed so Settings can set its own preview at the same weight the
    /// display will use, rather than guessing one.
    let cueNumberWeight: Font.Weight

    /// The same weight in AppKit's terms, for measuring.
    private let measuringWeight: NSFont.Weight

    init(preferences: Preferences) {
        self.usesRounded = preferences.usesRoundedSystemFont
        self.cueNumberWeight = preferences.fontWeight.weight
        self.measuringWeight = preferences.fontWeight.appKitWeight
    }

    /// The design to apply when using the system font.
    private var design: Font.Design {
        usesRounded ? .rounded : .default
    }

    /// The cue number at its ceiling size, for a caller that sizes the text by
    /// some other means.
    var cueNumber: Font {
        cueNumber(size: Self.cueNumberBaseSize)
    }

    /// The cue number at an explicit size: as heavy as the operator asked for,
    /// and as large as ``cueNumberPointSize(fitting:in:)`` worked out.
    func cueNumber(size: CGFloat) -> Font {
        font(size: size, weight: cueNumberWeight)
    }

    /// A cue name, whether the headline one or a drawer row's.
    func cueName(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        font(size: size, weight: weight)
    }

    /// A drawer row's number column.
    func drawerNumber(size: CGFloat, weight: Font.Weight) -> Font {
        font(size: size, weight: weight)
    }

    /// The system font at a given size and weight.
    ///
    /// The system font and nothing else, deliberately. Choosing an arbitrary
    /// installed family used to be offered and was withdrawn: it never worked.
    /// `Font/custom(_:size:)` resolves a *font* name, while the catalogue
    /// behind the picker listed *family* names, so most choices silently fell
    /// back to this anyway — and the system font is the right default besides,
    /// having the best numeric figures and the widest weight range of anything
    /// guaranteed to be installed.
    private func font(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    // MARK: - Fitting the cue number

    /// The point size at which `text` fills `space` in the cue-number font.
    ///
    /// Callers pass the *reference* number — the widest one this cue list can
    /// put in the slot, from ``widestCueNumber(among:)`` — rather than the
    /// number on screen. Every cue in the list is then drawn at one size,
    /// which is the point of measuring at all: an operator watching the
    /// display should not see the headline resize itself as the show runs.
    func cueNumberPointSize(fitting text: String, in space: CGSize) -> CGFloat {
        guard space.width > 0, space.height > 0, !text.isEmpty else {
            return Self.cueNumberMinimumSize
        }

        let measured = (text as NSString).size(
            withAttributes: [.font: measuringFont(size: Self.measuringPointSize)]
        )
        guard measured.width > 0, measured.height > 0 else { return Self.cueNumberMinimumSize }

        // Both axes, so a short number in a shallow window is limited by the
        // height it has rather than drawn past the top of it.
        let scale = min(space.width / measured.width, space.height / measured.height)
        let size = Self.measuringPointSize * scale
        return min(max(size, Self.cueNumberMinimumSize), Self.cueNumberBaseSize)
    }

    /// The widest of `candidates` in the cue-number font, or `nil` when there
    /// are none.
    ///
    /// Widths are summed from a table of character advances rather than
    /// measured string by string. A large show has thousands of cue numbers and
    /// this runs on every playhead move; measuring each number outright is
    /// milliseconds of main-thread work to answer a question that only needs
    /// the widest one. Kerning is ignored, which can only matter between two
    /// candidates of near-identical width — and the winner is then measured
    /// properly by ``cueNumberPointSize(fitting:in:)``.
    func widestCueNumber(among candidates: some Sequence<String>) -> String? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: measuringFont(size: Self.measuringPointSize)
        ]
        var advanceByCharacter: [Character: CGFloat] = [:]
        var widest: String?
        var widestWidth: CGFloat = 0

        for candidate in candidates {
            var width: CGFloat = 0
            for character in candidate {
                if let advance = advanceByCharacter[character] {
                    width += advance
                } else {
                    let advance = (String(character) as NSString)
                        .size(withAttributes: attributes).width
                    advanceByCharacter[character] = advance
                    width += advance
                }
            }
            if width > widestWidth {
                widestWidth = width
                widest = candidate
            }
        }
        return widest
    }

    /// The font cue numbers are measured with.
    ///
    /// `Font` cannot be measured — it describes a font rather than being one —
    /// so this rebuilds the same face in AppKit's terms: the operator's
    /// weight, their choice of design, and the monospaced figures the display
    /// draws with. A measurement of any other face would be worse than no
    /// measurement.
    private func measuringFont(size: CGFloat) -> NSFont {
        let system = NSFont.monospacedDigitSystemFont(ofSize: size, weight: measuringWeight)
        guard usesRounded,
              let descriptor = system.fontDescriptor.withDesign(.rounded)
        else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }
}
