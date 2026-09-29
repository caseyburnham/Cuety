import SwiftUI
#if os(macOS)
import AppKit
typealias MeasuringFont = NSFont
#else
import UIKit
typealias MeasuringFont = UIFont
#endif

@MainActor
struct Typography {
    static let cueNumberBaseSize: CGFloat = 720
    static let cueNumberMinimumScale: CGFloat = 0.02
    static var cueNumberMinimumSize: CGFloat { cueNumberBaseSize * cueNumberMinimumScale }
    static let measuringPointSize: CGFloat = 100

    let usesRounded: Bool
    let cueNumberWeight: Font.Weight
    let cueNumberSizing: CueNumberSizing
    let customCueNumberSize: CGFloat
    private let measuringWeight: MeasuringFont.Weight

    init(preferences: Preferences) {
        self.usesRounded = preferences.usesRoundedSystemFont
        self.cueNumberWeight = preferences.fontWeight.weight
        self.cueNumberSizing = preferences.cueNumberSizing
        self.customCueNumberSize = CGFloat(preferences.customCueNumberSize)
        self.measuringWeight = preferences.fontWeight.platformWeight
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

    /// The size to draw the standby number `text` at, following the sizing
    /// preference. `reference` is the widest number in the cue list, which
    /// fixed sizing fits so every cue in the list is drawn at the same size.
    /// A custom size is shrunk when `text` would not otherwise fit `space`.
    func standbyNumberPointSize(for text: String, reference: String, in space: CGSize) -> CGFloat {
        switch cueNumberSizing {
        case .fixed:
            cueNumberPointSize(fitting: reference, in: space)
        case .custom:
            min(customCueNumberSize, cueNumberPointSize(fitting: text, in: space))
        case .dynamic:
            cueNumberPointSize(fitting: text, in: space)
        }
    }

    /// The height of one line of text at `size`, as `Text` lays it out. The
    /// line height barely moves with weight, so the cue number's is used.
    func lineHeight(size: CGFloat) -> CGFloat {
        let measured = ("0" as NSString).size(
            withAttributes: [.font: measuringFont(size: Self.measuringPointSize)]
        )
        return measured.height * size / Self.measuringPointSize
    }

    func cueNumberWidth(of text: String, size: CGFloat) -> CGFloat {
        let measured = (text as NSString).size(
            withAttributes: [.font: measuringFont(size: Self.measuringPointSize)]
        )
        return measured.width * size / Self.measuringPointSize
    }

    /// Whole strings are measured, not summed character advances, so kerning
    /// and shaping in arbitrary identifiers ("SQ-104", "A12") count too.
    func widestCueNumber(among candidates: some Sequence<String>) -> String? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: measuringFont(size: Self.measuringPointSize)
        ]
        var measured = Set<String>()
        var widest: String?
        var widestWidth: CGFloat = 0

        for candidate in candidates where measured.insert(candidate).inserted {
            let width = (candidate as NSString).size(withAttributes: attributes).width
            if width > widestWidth {
                widestWidth = width
                widest = candidate
            }
        }
        return widest
    }

    /// The width `text` takes as a drawer number: `drawerNumber(size:weight:)`
    /// with `.monospacedDigit()`, rounded up to whole points.
    func drawerNumberWidth(of text: String, size: CGFloat, weight: Font.Weight) -> CGFloat {
        let font = measuringFont(size: size, weight: Self.platformWeight(for: weight))
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    private static func platformWeight(for weight: Font.Weight) -> MeasuringFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    /// The platform font matching what `font(size:weight:)` renders once
    /// `.monospacedDigit()` is applied, including the rounded design.
    private func measuringFont(size: CGFloat, weight: MeasuringFont.Weight? = nil) -> MeasuringFont {
        let font = MeasuringFont.monospacedDigitSystemFont(
            ofSize: size, weight: weight ?? measuringWeight
        )
        guard usesRounded,
              let rounded = font.fontDescriptor.withDesign(.rounded)
        else { return font }
#if os(macOS)
        return MeasuringFont(descriptor: rounded, size: size) ?? font
#else
        return MeasuringFont(descriptor: rounded, size: size)
#endif
    }
}
