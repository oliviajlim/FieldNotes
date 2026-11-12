import SwiftUI

struct AudioVisualizerView: View {
    private enum Mode {
        case waveform, waterfall, spectrum
    }

    let samples: OscilloscopeSamples
    let isActive: Bool
    let sourceLabel: String

    @State private var mode = Mode.waveform
    @State private var gain = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Visualizer")
                    .font(AppFont.headline)
                    .foregroundStyle(FieldNoteTheme.ink)
                Text(sourceLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(FieldNoteTheme.mutedInk)
            }

            Picker("Visualizer mode", selection: $mode) {
                Text("Waveform").tag(Mode.waveform)
                Text("3D").accessibilityLabel("3D waveform").tag(Mode.waterfall)
                Text("Spectrum").tag(Mode.spectrum)
            }
            .pickerStyle(.segmented)

            if mode == .spectrum {
                SpectrumBarsView(samples: samples, isActive: isActive, sourceLabel: sourceLabel)
            } else {
                OscilloscopeView(
                    samples: samples,
                    isActive: isActive,
                    sourceLabel: sourceLabel,
                    showsDepth: mode == .waterfall,
                    gain: $gain
                )
            }
        }
        .padding(12)
        .background(FieldNoteTheme.surface, in: .rect(cornerRadius: 12))
    }
}

#Preview {
    AudioVisualizerView(samples: OscilloscopeSamples(), isActive: false, sourceLabel: "Idle")
        .padding()
}
