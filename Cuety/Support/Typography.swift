import SwiftUI

/// Resolves the user's font choice into concrete `Font` values.
///
/// The cue number is set at a deliberately huge base size and allowed to scale
/// down to fit. That is the native way to get "as big as the window allows"
/// without measuring text by hand: `minimumScaleFactor` does the work, and it
/// stays correct through window resizes and presentation mode with no layout
/// passes of our own.
@MainActor
struct Typography {
    /// The base point size for the cue number. Far larger than any window, so
    /// the scale factor always drives the final size.
    static let cueNumberBaseSize: CGFloat = 720

    /// The floor for the cue number, as a fraction of the base size. Low
    /// enough that a long number like "127.5" still fits a narrow window.
    static let cueNumberMinimumScale: CGFloat = 0.02

    let familyName: String?
    let usesRounded: Bool

    /// The operator's chosen weight for the cue number.
    ///
    /// Exposed so Settings can set its own preview at the same weight the
    /// display will use, rather than guessing one.
    let cueNumberWeight: Font.Weight

    init(preferences: Preferences) {
        self.familyName = preferences.fontFamily
        self.usesRounded = preferences.usesRoundedSystemFont
        self.cueNumberWeight = preferences.fontWeight.weight
    }

    /// The design to apply when using the system font.
    private var design: Font.Design {
        usesRounded ? .rounded : .default
    }

    /// The cue number: as heavy as the operator asked for, tabular, and as
    /// large as will fit.
    var cueNumber: Font {
        font(size: Self.cueNumberBaseSize, weight: cueNumberWeight)
    }

    /// A cue name, whether the headline one or a drawer row's.
    func cueName(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        font(size: size, weight: weight)
    }

    /// A drawer row's number column.
    func drawerNumber(size: CGFloat, weight: Font.Weight) -> Font {
        font(size: size, weight: weight)
    }

    /// The operator's chosen family at a given size, falling back to the system
    /// font.
    ///
    /// The weight is applied either way. It is what separates the cue standing
    /// by from the ones around it, so a custom family has to honour it too —
    /// otherwise picking a font would flatten the drawer's hierarchy.
    private func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard let familyName else {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(familyName, size: size).weight(weight)
    }
}

/// The catalogue of fonts available for the cue display.
///
/// Reads the installed families through `NSFontManager` — the documented AppKit
/// API — rather than scanning font directories.
@MainActor
struct FontCatalog {
    /// Families installed on this Mac, alphabetically.
    ///
    /// Filtered to families that can actually render digits legibly at size:
    /// symbol and dingbat families would produce a cue display of glyphs.
    static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                // A family that can't draw "0" is no use for a cue number.
                return font.glyphAvailable(for: "0")
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A short list of families that suit a large numeric readout, offered
    /// above the full list so the choice isn't a wall of names.
    static var recommendedFamilies: [String] {
        let candidates = [
            "SF Pro", "SF Pro Display", "SF Compact Display", "SF Mono",
            "Helvetica Neue", "Avenir Next", "Futura", "Menlo",
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidates.filter(installed.contains)
    }
}

private extension NSFont {
    /// Whether the font has a glyph for the given character.
    func glyphAvailable(for character: Character) -> Bool {
        guard let scalar = String(character).unicodeScalars.first,
              let utf16Unit = UnicodeScalar(scalar.value)?.utf16.first
        else { return false }

        var characters: [UniChar] = [utf16Unit]
        var glyphs: [CGGlyph] = [0]
        return CTFontGetGlyphsForCharacters(self, &characters, &glyphs, 1) && glyphs[0] != 0
    }
}
