import SwiftUI

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

    var unit: LocalizedStringKey?

    var showsStepper: Bool = true

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: format)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)

                Text(unit ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 8, alignment: .leading)

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
