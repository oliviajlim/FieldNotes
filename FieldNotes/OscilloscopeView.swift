import SwiftUI

/// Time runs left to right; positive and negative amplitudes sit above and
/// below the center line. Gain changes the drawing, never the recorded audio.
struct OscilloscopeView: View {
    let samples: OscilloscopeSamples
    let isActive: Bool
    let sourceLabel: String
    let showsDepth: Bool
    @Binding var gain: Double

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation(
                minimumInterval: reduceMotion ? 1.0 / 10 : 1.0 / 30,
                paused: !isActive || scenePhase != .active
            )) { _ in
                let snapshot = isActive
                    ? samples.snapshot(includeHistory: showsDepth)
                    : .empty

                VStack(alignment: .leading, spacing: 4) {
                    Canvas { context, size in
                        if showsDepth {
                            drawWaterfall(snapshot.frames, in: context, size: size)
                        } else {
                            drawGrid(in: context, size: size)
                            drawTrace(snapshot.samples, in: context, size: size)
                        }
                    }
                    .frame(height: showsDepth ? 200 : 160)
                    .background(Color(red: 0.015, green: 0.035, blue: 0.025))
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel(showsDepth ? "3D audio waveform" : "Audio waveform")
                    .accessibilityValue(sourceLabel)

                    Text("Window: \((snapshot.duration * 1000).formatted(.number.precision(.fractionLength(1)))) ms · Channel 1")
                        .font(AppFont.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack {
                Text("Display gain")
                    .foregroundStyle(.secondary)
                Slider(value: $gain, in: 1...20, step: 1)
                    .accessibilityLabel("Display gain")
                    .accessibilityValue("\(Int(gain)) times")
                Text("×\(Int(gain))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .font(AppFont.caption)
        }
    }

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for division in 1..<8 {
            let x = size.width * CGFloat(division) / 8
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for division in 1..<4 {
            let y = size.height * CGFloat(division) / 4
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(Color.green.opacity(0.25)), lineWidth: 0.5)
    }

    private func drawTrace(_ samples: [Float], in context: GraphicsContext, size: CGSize) {
        let trace = tracePath(samples, maxPoints: 1024) { x, amplitude in
            CGPoint(x: x * size.width, y: size.height * (0.5 - amplitude * 0.45))
        }
        context.stroke(trace, with: .color(Color.green.opacity(0.12)), lineWidth: 6)
        context.stroke(trace, with: .color(Color.green), lineWidth: 1.2)
    }

    private func drawWaterfall(_ frames: [[Float]], in context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for division in 0...8 {
            let fraction = CGFloat(division) / 8
            grid.move(to: project(x: 0, amplitude: 0, depth: fraction, size: size))
            grid.addLine(to: project(x: 1, amplitude: 0, depth: fraction, size: size))
            grid.move(to: project(x: fraction, amplitude: 0, depth: 0, size: size))
            grid.addLine(to: project(x: fraction, amplitude: 0, depth: 1, size: size))
        }
        context.stroke(grid, with: .color(Color.green.opacity(0.3)), lineWidth: 0.5)

        // Draw the oldest trace first so the brightest trace sits in front.
        for (index, samples) in frames.enumerated() {
            let age = frames.count - index - 1
            let depth = CGFloat(age) / CGFloat(OscilloscopeSamples.historyCapacity - 1)
            let trace = tracePath(samples, maxPoints: 256) { x, amplitude in
                project(x: x, amplitude: amplitude, depth: depth, size: size)
            }
            let traceColor = Color.green.opacity(1 - depth * 0.78)
            context.stroke(trace, with: .color(traceColor), lineWidth: 1.4 - depth * 0.65)
        }
    }

    /// Older frames move up and shrink toward the back of the grid.
    private func project(x: CGFloat, amplitude: CGFloat, depth: CGFloat, size: CGSize) -> CGPoint {
        let scale = 1 - 0.46 * depth
        return CGPoint(
            x: size.width * (0.48 + 0.12 * depth + (x - 0.5) * 0.9 * scale),
            y: size.height * (0.68 - 0.46 * depth - amplitude * 0.28 * scale)
        )
    }

    private func tracePath(
        _ samples: [Float],
        maxPoints: Int,
        point: (CGFloat, CGFloat) -> CGPoint
    ) -> Path {
        var trace = Path()
        let count = min(samples.count, maxPoints)
        guard count > 1 else {
            trace.move(to: point(0, 0))
            trace.addLine(to: point(1, 0))
            return trace
        }

        for index in 0..<count {
            let x = CGFloat(index) / CGFloat(count - 1)
            let sampleIndex = index * (samples.count - 1) / (count - 1)
            let amplified = Double(samples[sampleIndex]) * gain
            let amplitude = amplified.isFinite ? min(1, max(-1, amplified)) : 0
            let position = point(x, CGFloat(amplitude))
            if index == 0 {
                trace.move(to: position)
            } else {
                trace.addLine(to: position)
            }
        }
        return trace
    }
}
