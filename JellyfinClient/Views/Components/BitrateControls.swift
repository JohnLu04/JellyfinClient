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

/// Streaming quality: "Original" (no limit), "Automatic" (follows the connection) or a fixed limit in
/// 0.5 Mbit/s steps. `mbit == 0` means Original, `Bitrate.automatic` (negative) means Automatic.
struct StreamingQualityControl: View {
    @Binding var mbit: Double
    @State private var lastLimit = 8.0

    private enum Mode: Hashable { case original, automatic, limit }

    private var mode: Binding<Mode> {
        Binding(
            get: { Bitrate.isAutomatic(mbit) ? .automatic : (mbit > 0 ? .limit : .original) },
            set: { mode in
                switch mode {
                case .original: mbit = 0
                case .automatic: mbit = Bitrate.automatic
                case .limit: mbit = lastLimit
                }
            })
    }

    var body: some View {
        Picker("Quality", selection: mode) {
            Text("Original").tag(Mode.original)
            Text("Automatic").tag(Mode.automatic)
            Text("Limit").tag(Mode.limit)
        }
        .pickerStyle(.segmented)
        if Bitrate.isAutomatic(mbit) {
            Text("Follows your Wi-Fi or mobile connection: the quality steps down before the buffer runs out and back up when there's room, without the video reloading.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if mbit > 0 {
            BitrateStepper(title: "Max. bitrate", mbit: Binding(
                get: { mbit },
                set: { mbit = $0; lastLimit = $0 }
            ))
        }
    }
}
