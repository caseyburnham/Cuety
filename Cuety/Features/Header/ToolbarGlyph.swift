import SwiftUI

@MainActor
@Observable
final class ToolbarGlyphState {
    var symbol: String

    var tint: Color?

    var beat = 0

    var isWorking = false

    init(symbol: String) {
        self.symbol = symbol
    }
}

struct ToolbarGlyph: View {
    let state: ToolbarGlyphState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: state.symbol)
            .imageScale(.large)
            .foregroundStyle(state.tint ?? .primary)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : state.beat)
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && state.isWorking)
            .motion(Motion.status, value: state.symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
