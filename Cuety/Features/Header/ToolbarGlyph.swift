import SwiftUI

/// The state of one toolbar glyph, so ``SymbolToolbarButton`` can drive a
/// SwiftUI view from AppKit.
@MainActor
@Observable
final class ToolbarGlyphState {
    /// The symbol on show.
    var symbol: String

    /// The glyph's colour, or `nil` for the standard template rendering.
    var tint: Color?

    /// Bumped to bounce the glyph once.
    ///
    /// A counter rather than a flag because `symbolEffect(_:options:value:)`
    /// fires on the value *changing*, and two heartbeats in a row have to read
    /// as two beats.
    var beat = 0

    /// Whether to cycle the glyph's layers to convey work in progress.
    var isWorking = false

    init(symbol: String) {
        self.symbol = symbol
    }
}

/// A toolbar glyph, drawn in SwiftUI inside an AppKit button.
///
/// SwiftUI rather than `NSImageView`'s symbol effects, deliberately, and after
/// trying it the other way. The vocabulary exists in both, but the AppKit
/// spelling never produced a true magic replace here: `heart.fill` becoming
/// `heart.slash.fill` came out as two glyphs moving past each other and
/// changing size, rather than a slash arriving across a heart. This exact
/// expression has been drawing the same pair correctly in the connection
/// inspector the whole time — see ``HeartbeatIndicator`` — so the toolbar uses
/// it too instead of a second, worse implementation of the same thing.
///
/// Reduce Motion comes with it, through ``SwiftUICore/View/motion(_:value:)``,
/// rather than from an `NSWorkspace` check at the call site.
struct ToolbarGlyph: View {
    let state: ToolbarGlyphState

    var body: some View {
        Image(systemName: state.symbol)
            // Matches the scale the button measures itself at.
            .imageScale(.large)
            .foregroundStyle(state.tint ?? .primary)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(.bounce, options: .nonRepeating, value: state.beat)
            .symbolEffect(.variableColor.iterative, isActive: state.isWorking)
            .motion(Motion.status, value: state.symbol)
            // Centred in whatever the button gives it, so the glyph's own size
            // never decides the button's and nothing reflows mid-transition.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
