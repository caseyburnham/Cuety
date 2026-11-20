import SwiftUI
#if os(macOS)
import AppKit
typealias MeasuringFont = NSFont
#else
import UIKit
typealias MeasuringFont = UIFont
#endif

@MainActor
struct Typography: Equatable {
    static let cueNumberBaseSize: CGFloat = 720
    static let cueNumberMinimumScale: CGFloat = 0.02
    static var cueNumberMinimumSize: CGFloat { cueNumberBaseSize * cueNumberMinimumScale }
    static let measuringPointSize: CGFloat = 100

    let usesRounded: Bool
    let cueNumberWeight: Font.Weight
    private let measuringWeight: MeasuringFont.Weight

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: MeasuringFont.Weight
        let usesRounded: Bool
    }

    private static var fontCache: [FontKey: MeasuringFont] = [:]

    init(preferences: Preferences) {
        self.usesRounded = preferences.usesRoundedSystemFont
        self.cueNumberWeight = preferences.fontWeight.weight
        self.measuringWeight = Self.platformWeight(for: preferences.fontWeight.weight)
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

    /// The system font in the chosen design. Names default to medium weight.
    func font(size: CGFloat, weight: Font.Weight = .medium) -> Font {
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
        let digitWidth = ("0" as NSString).size(withAttributes: attributes).width

        var seen = Set<String>()
        var nonDigitCandidates: [String] = []
        var longestDigitCandidate: String?
        var maxDigitCount = 0

        for candidate in candidates where seen.insert(candidate).inserted {
            guard !candidate.isEmpty else { continue }
            if candidate.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
                if candidate.count > maxDigitCount {
                    maxDigitCount = candidate.count
                    longestDigitCandidate = candidate
                }
            } else {
                nonDigitCandidates.append(candidate)
            }
        }

        var widest: String? = longestDigitCandidate
        var widestWidth: CGFloat = CGFloat(maxDigitCount) * digitWidth

        guard !nonDigitCandidates.isEmpty else {
            return widest
        }

        // SF system font glyph advance ceiling for ASCII characters at 100pt.
        let maxAsciiAdvance: CGFloat = 105
        nonDigitCandidates.sort { $0.count > $1.count }

        for candidate in nonDigitCandidates {
            let isAscii = candidate.utf8.allSatisfy { $0 < 0x80 }
            if isAscii && CGFloat(candidate.count) * maxAsciiAdvance <= widestWidth {
                continue
            }

            let width = (candidate as NSString).size(withAttributes: attributes).width
            if width > widestWidth {
                widestWidth = width
                widest = candidate
            }
        }

        return widest
    }

    /// The width `text` takes as a drawer number: `font(size:weight:)`
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
        let resolvedWeight = weight ?? measuringWeight
        let key = FontKey(size: size, weight: resolvedWeight, usesRounded: usesRounded)
        if let cached = Self.fontCache[key] {
            return cached
        }

        let base = MeasuringFont.monospacedDigitSystemFont(ofSize: size, weight: resolvedWeight)
        let resolved: MeasuringFont
        if usesRounded, let rounded = base.fontDescriptor.withDesign(.rounded) {
#if os(macOS)
            resolved = MeasuringFont(descriptor: rounded, size: size) ?? base
#else
            resolved = MeasuringFont(descriptor: rounded, size: size)
#endif
        } else {
            resolved = base
        }

        Self.fontCache[key] = resolved
        return resolved
    }
}
