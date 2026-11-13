import SwiftUI

/// Picks a bitrate in 0.5 Mbit/s steps: the stepper for fine control, the slider for big jumps.
struct BitrateStepper: View {
    var title: LocalizedStringKey = "Bitrate"
    @Binding var mbit: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: snapped, in: Bitrate.range, step: Bitrate.step) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Bitrate.label(mbit))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: snapped, in: Bitrate.range, step: Bitrate.step) {
                Text(title)
            } minimumValueLabel: {
                Text(Bitrate.range.lowerBound.formatted()).font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(Bitrate.range.upperBound.formatted()).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var snapped: Binding<Double> {
        Binding(get: { Bitrate.snap(mbit) }, set: { mbit = Bitrate.snap($0) })
    }
}

/// Streaming quality: "Original" (no limit) or a limit in 0.5 Mbit/s steps. `mbit == 0` means Original.
struct StreamingQualityControl: View {
    @Binding var mbit: Double
    @State private var lastLimit = 8.0

    var body: some View {
        Toggle("Limit bitrate (transcode)", isOn: Binding(
            get: { mbit > 0 },
            set: { mbit = $0 ? lastLimit : 0 }
        ))
        if mbit > 0 {
            BitrateStepper(title: "Max. bitrate", mbit: Binding(
                get: { mbit },
                set: { mbit = $0; lastLimit = $0 }
            ))
        }
    }
}
