import SwiftUI

/// A bounded number the operator can type, with stepper arrows beside it.
///
/// The macOS idiom for a numeric setting, and the reason it exists here is
/// that a bare `Stepper` offers *only* the arrows. Going from three drawer
/// rows to ten meant seven clicks, and the value itself sat inside the
/// label as prose — "Rows above the playhead: 3" — where it read as a
/// statement rather than as something editable. The field is the primary
/// control now and the arrows are the nudge.
///
/// Range enforcement is deliberately duplicated: the `Stepper` will not step
/// past `range`, and the field cannot be stopped from accepting a typed
/// number outside it — so the clamping setters in ``Preferences`` remain the
/// backstop, and a value typed out of range snaps to the nearest bound.
struct SteppedField<Value, Format>: View
where Value: Strideable & Comparable,
      Value.Stride: SignedNumeric,
      Format: ParseableFormatStyle,
      Format.FormatInput == Value,
      Format.FormatOutput == String {

    let title: LocalizedStringKey

    @Binding var value: Value

    let range: ClosedRange<Value>

    var step: Value.Stride = 1

    let format: Format

    /// A unit shown after the field — `"s"` for an interval — so the number
    /// does not have to carry it in the label.
    var unit: LocalizedStringKey?

    /// Whether the arrows appear at all.
    ///
    /// Off for a port: nudging 53000 to 53001 is not a thing anyone wants to
    /// do one click at a time, and arrows invited it. The arrows' *footprint*
    /// is kept either way — see ``body`` — so the fields in a section still
    /// share one right edge.
    var showsStepper: Bool = true

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: format)
                    .labelsHidden()
                    // Bordered explicitly. Inside a `LabeledContent` in a
                    // grouped `Form` the automatic style can draw no bezel at
                    // all, which is what made the port field look like a
                    // read-only value rather than something to type into.
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)

                // The slot is held open whether there is a unit or not, so a
                // column of these fields has one right edge. Sized for "s",
                // which is the only unit any setting here takes.
                Text(unit ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 8, alignment: .leading)

                // Hidden rather than absent when it isn't wanted, so that a
                // section mixing stepped and unstepped fields still lines its
                // fields up instead of leaving one row reaching further right
                // than its neighbours. Untouchable and unspoken to VoiceOver
                // as well as invisible — an arrow you cannot see but can still
                // click is worse than either.
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .opacity(showsStepper ? 1 : 0)
                    .allowsHitTesting(showsStepper)
                    .accessibilityHidden(!showsStepper)
            }
        } label: {
            Text(title)
        }
    }
}

#Preview {
    @Previewable @State var rows = 3
    @Previewable @State var seconds = 5.0
    @Previewable @State var port = 53_000

    Form {
        Section("Cue Drawer") {
            SteppedField(
                title: "Rows above the playhead",
                value: $rows,
                range: 0...10,
                format: IntegerFormatStyle<Int>.number.grouping(.never)
            )
        }

        Section("Connection") {
            SteppedField(
                title: "TCP port",
                value: $port,
                range: 1...65_535,
                format: IntegerFormatStyle<Int>.number.grouping(.never),
                showsStepper: false
            )

            SteppedField(
                title: "Heartbeat",
                value: $seconds,
                range: 1...60,
                format: FloatingPointFormatStyle<Double>.number
                    .precision(.fractionLength(0)),
                unit: "s"
            )
        }
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
