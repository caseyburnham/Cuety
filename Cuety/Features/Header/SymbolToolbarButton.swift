import AppKit
import SwiftUI

/// A bordered toolbar button whose glyph is an SF Symbol that can animate.
///
/// AppKit for the button, SwiftUI for the glyph inside it, because each is the
/// one that works. `NSButton` with the toolbar bezel is what gives the standard
/// hover, press and on-state response — a SwiftUI toolbar item whose label is
/// anything but a plain `Label` is treated as custom content and gets none of
/// it. The glyph is the other way round: `NSImageView`'s symbol effects would
/// not magic-replace these symbol pairs properly, and SwiftUI's do. See
/// ``ToolbarGlyph``.
final class SymbolToolbarButton: NSButton {
    /// Hosts the glyph, and refuses the mouse so every click, hover and press
    /// reaches the button underneath.
    ///
    /// Without the hit-test refusal the glyph swallows the event and the bezel
    /// never lights up.
    private final class GlyphHostingView: NSHostingView<ToolbarGlyph> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Toolbar glyphs are the large-scale variant of a symbol at the system's
    /// default point size. Asked for by scale rather than by a literal size,
    /// so the glyph tracks whatever the system considers standard instead of a
    /// number chosen once and left behind. ``ToolbarGlyph`` asks SwiftUI for
    /// the same scale.
    private static let symbolConfiguration = NSImage.SymbolConfiguration(scale: .large)

    /// The last resort if not one of a button's symbols can be loaded, which
    /// should not happen. A glyph-sized button beats a zero-sized one.
    private static let fallbackGlyphSize = NSSize(width: 16, height: 16)

    /// Named for the glyph rather than just `state`, because `NSControl`
    /// already has a `state` and this would shadow the on/off value the
    /// keep-awake toggle's bezel reads.
    private let glyphState: ToolbarGlyphState
    private let glyph: GlyphHostingView

    /// - Parameter symbols: Every symbol this button can ever show. All of
    ///   them, not just the first: the button is sized to fit the widest, and
    ///   a toolbar item that changed width when its glyph changed would shove
    ///   its neighbours around each time the state moved.
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
        // One glyph and no title is what a circular toolbar button is for, and
        // a circle is the shape the rest of the system gives one.
        borderShape = .circle
        title = ""
        setAccessibilityLabel(accessibilityLabel)

        // The cell gets a real, correctly sized image, even though the glyph
        // on top is what is actually seen.
        //
        // Load-bearing rather than tidiness. `NSButtonCell` derives its mouse
        // tracking rect from its content, so a cell holding neither image nor
        // title has an all but empty one: the bezel still drew and still lit
        // up under the pointer, but a mouse-up anywhere other than dead centre
        // landed outside the cell and no action was ever sent. An empty cell
        // also has no intrinsic size, and gives AppKit nothing to recognise as
        // an icon-only button when it picks a bezel.
        //
        // The placeholder draws nothing, so the glyph is still drawn exactly
        // once. It is sized to the widest symbol this button can ever show, so
        // the item's width does not change when its state does.
        image = Self.placeholder(size: Self.glyphSize(fitting: symbols))
        imagePosition = .imageOnly
        imageScaling = .scaleNone

        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        // Pinned to the button's edges, and deliberately unwilling to influence
        // its size: the cell's placeholder decides how big the button is, and
        // the glyph centres itself in whatever it gets. Sizing the host from
        // its content instead would resize it whenever the symbol changed,
        // which is a box that moves while a transition animates inside it.
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

    // MARK: Glyph

    /// Shows `symbol`, magic-replacing whatever is on screen when it changes.
    ///
    /// Magic replace keeps the part the two glyphs share in place and draws
    /// only the difference — a slash arriving across a heart, rays growing on
    /// a sun — so a state change reads as this glyph changing rather than as
    /// one glyph cutting to another.
    func setSymbol(_ symbol: String) {
        glyphState.symbol = symbol
    }

    /// The glyph's colour. `nil` restores the standard template rendering.
    var glyphTint: Color? {
        get { glyphState.tint }
        set { glyphState.tint = newValue }
    }

    /// Bounces the glyph once.
    func bounce() {
        glyphState.beat += 1
    }

    /// Cycles the glyph's layers to convey work in progress, or stops.
    func setWorking(_ working: Bool) {
        glyphState.isWorking = working
    }

    // MARK: Metrics

    /// The size the glyph needs in order to render any of `symbols`.
    ///
    /// Measured through `NSImageView`, which still renders symbols at the same
    /// metrics even though the glyph itself is drawn in SwiftUI now — asking
    /// the system beats picking numbers, and the alternative is measuring a
    /// hosting view mid-initialiser.
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

    /// An image of `size` that draws nothing.
    ///
    /// Only the size matters. It stands in for the glyph so the cell has
    /// content to measure and track against, while leaving the drawing to the
    /// hosted view — see the note in `init`. Button metrics are left to AppKit
    /// from there: hand-tuned ones are the thing a real toolbar item was
    /// supposed to stop Cuety needing.
    private static func placeholder(size: NSSize) -> NSImage {
        let placeholder = NSImage(size: size, flipped: false) { _ in true }
        placeholder.isTemplate = true
        return placeholder
    }
}
