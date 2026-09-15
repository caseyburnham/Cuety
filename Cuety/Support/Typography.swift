import SwiftUI

@MainActor
struct Typography {
    static let cueNumberBaseSize: CGFloat = 720

    static let cueNumberMinimumScale: CGFloat = 0.02

    static var cueNumberMinimumSize: CGFloat { cueNumberBaseSize * cueNumberMinimumScale }

    static let measuringPointSize: CGFloat = 100

    let usesRounded: Bool

    let cueNumberWeight: Font.Weight

    private let measuringWeight: NSFont.Weight

    init(preferences: Preferences) {
        self.usesRounded = preferences.usesRoundedSystemFont
        self.cueNumberWeight = preferences.fontWeight.weight
        self.measuringWeight = preferences.fontWeight.appKitWeight
    }

    private var design: Font.Design {
        usesRounded ? .rounded : .default
    }

    var cueNumber: Font {
        cueNumber(size: Self.cueNumberBaseSize)
    }

    func cueNumber(size: CGFloat) -> Font {
        font(size: size, weight: cueNumberWeight)
    }

    func cueName(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        font(size: size, weight: weight)
    }

    func drawerNumber(size: CGFloat, weight: Font.Weight) -> Font {
        font(size: size, weight: weight)
    }

    private func font(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: design)
    }


    func cueNumberPointSize(fitting text: String, in space: CGSize) -> CGFloat {
        guard space.width > 0, space.height > 0, !text.isEmpty else {
            return Self.cueNumberMinimumSize
        }

        let measured = (text as NSString).size(
            withAttributes: [.font: measuringFont(size: Self.measuringPointSize)]
        )
        guard measured.width > 0, measured.height > 0 else { return Self.cueNumberMinimumSize }

        let scale = min(space.width / measured.width, space.height / measured.height)
        let size = Self.measuringPointSize * scale
        return min(max(size, Self.cueNumberMinimumSize), Self.cueNumberBaseSize)
    }

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

    private func measuringFont(size: CGFloat) -> NSFont {
        let system = NSFont.monospacedDigitSystemFont(ofSize: size, weight: measuringWeight)
        guard usesRounded,
              let descriptor = system.fontDescriptor.withDesign(.rounded)
        else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }
}
