import AppKit
import SwiftUI

final class SymbolToolbarButton: NSButton {
    private final class GlyphHostingView: NSHostingView<ToolbarGlyph> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class NonInteractiveProgressIndicator: NSProgressIndicator {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private static let symbolConfiguration = NSImage.SymbolConfiguration(scale: .large)

    private static let fallbackGlyphSize = NSSize(width: 16, height: 16)

    private let glyphState: ToolbarGlyphState
    private let glyph: GlyphHostingView

    init(
        symbols: [String],
        accessibilityLabel: String,
        target: AnyObject?,
        action: Selector
    ) {
        glyphState = ToolbarGlyphState(symbol: symbols.first ?? "")
        glyph = GlyphHostingView(rootView: ToolbarGlyph(state: glyphState))
        super.init(frame: .zero)

        self.target = target
        self.action = action
        bezelStyle = .toolbar
        isBordered = true
        borderShape = .circle
        title = ""
        setAccessibilityLabel(accessibilityLabel)

        image = Self.placeholder(size: Self.glyphSize(fitting: symbols))
        imagePosition = .imageOnly
        imageScaling = .scaleNone

        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        glyph.setContentHuggingPriority(.init(1), for: .horizontal)
        glyph.setContentHuggingPriority(.init(1), for: .vertical)
        glyph.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        glyph.setContentCompressionResistancePriority(.init(1), for: .vertical)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor),
            glyph.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SymbolToolbarButton is built in code, never from a nib")
    }


    func setSymbol(_ symbol: String) {
        glyphState.symbol = symbol
    }

    var glyphTint: Color? {
        get { glyphState.tint }
        set { glyphState.tint = newValue }
    }

    func bounce() {
        glyphState.beat += 1
    }

    private var spinner: NonInteractiveProgressIndicator?

    func setSpinning(_ spinning: Bool) {
        if spinning, spinner == nil {
            let indicator = NonInteractiveProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.isDisplayedWhenStopped = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            spinner = indicator
        }

        glyph.isHidden = spinning
        if spinning {
            spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
        }
    }

    func setWorking(_ working: Bool) {
        glyphState.isWorking = working
    }


    private static func glyphSize(fitting symbols: [String]) -> NSSize {
        let sizer = NSImageView()
        sizer.symbolConfiguration = symbolConfiguration
        var size = NSSize.zero

        for symbol in symbols {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            else { continue }
            sizer.image = image
            let fit = sizer.intrinsicContentSize
            size.width = max(size.width, fit.width)
            size.height = max(size.height, fit.height)
        }

        guard size.width > 0, size.height > 0 else { return fallbackGlyphSize }
        return size
    }

    private static func placeholder(size: NSSize) -> NSImage {
        let placeholder = NSImage(size: size, flipped: false) { _ in true }
        placeholder.isTemplate = true
        return placeholder
    }
}
