import SwiftUI

struct NumericField<Value, Format>: View
where Format: ParseableFormatStyle,
      Value: Equatable,
      Format.FormatInput == Value,
      Format.FormatOutput == String {

    let title: LocalizedStringKey

    @Binding var value: Value

    let format: Format

    var unit: LocalizedStringKey? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: format)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)

                // Reserve the unit column so optional units keep fields aligned.
                Text(unit ?? "s")
                    .foregroundStyle(.secondary)
                    .frame(width: 8, alignment: .leading)
                    .opacity(unit == nil ? 0 : 1)
                    .accessibilityHidden(unit == nil)
            }
        } label: {
            Text(title)
        }
    }
}
