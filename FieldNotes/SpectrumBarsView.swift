import SwiftUI

struct SpectrumBarsView: View {
    let samples: OscilloscopeSamples
    let isActive: Bool
    let sourceLabel: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bars: [SpectrumBar] = []

    private var refreshInterval: Duration? {
        guard isActive, scenePhase == .active else { return nil }
        return .seconds(reduceMotion ? 0.1 : 1.0 / 30)
    }

    var body: some View {
        let interval = refreshInterval
        let visibleBars = interval == nil ? [] : bars

        VStack(spacing: 4) {
            Canvas { context, size in
                draw(visibleBars, in: context, size: size)
            }
            .frame(height: 160)
            .background(FieldNoteTheme.evergreen)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel("Audio spectrum, low to high frequency")
            .accessibilityValue(sourceLabel)

            HStack {
                Text("Low frequencies")
                Spacer()
                Text("High frequencies")
            }
            .font(AppFont.caption2)
            .foregroundStyle(FieldNoteTheme.mutedInk)
            .accessibilityHidden(true)
        }
        .task(id: interval) {
            bars = []
            guard let interval, let analyzer = SpectrumAnalyzer() else { return }
            await updateBars(using: analyzer, interval: interval)
        }
    }

    private func updateBars(using analyzer: SpectrumAnalyzer, interval: Duration) async {
        let clock = ContinuousClock()
        var previousTime = clock.now
        var sourceGeneration: UInt64?
        var currentBars: [SpectrumBar] = []

        while !Task.isCancelled {
            let now = clock.now
            let elapsed = (now - previousTime) / .seconds(1)
            previousTime = now
            let snapshot = samples.snapshot()
            let levels = analyzer.bandDecibels(for: snapshot.samples, sampleRate: snapshot.sampleRate)

            if sourceGeneration != snapshot.sourceGeneration || currentBars.count != levels.count {
                currentBars = [SpectrumBar](repeating: SpectrumBar(), count: levels.count)
                sourceGeneration = snapshot.sourceGeneration
            }
            let decay = pow(0.9, elapsed * 30)
            for (index, decibels) in levels.enumerated() {
                currentBars[index].update(decibels: decibels, decay: decay, elapsed: elapsed)
            }
            if bars != currentBars { bars = currentBars }

            do {
                try await clock.sleep(until: now + interval)
            } catch {
                return
            }
        }
    }

    private func draw(_ bars: [SpectrumBar], in context: GraphicsContext, size: CGSize) {
        let plot = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        guard plot.width > 0, plot.height > 0 else { return }

        var grid = Path()
        for division in 1...4 {
            let y = plot.minY + plot.height * CGFloat(division) / 4
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.stroke(grid, with: .color(FieldNoteTheme.leaf.opacity(0.2)), lineWidth: 0.5)

        let slotWidth = plot.width / CGFloat(max(1, bars.count))
        let barWidth = slotWidth * 0.78
        var columns = Path()
        var caps = Path()
        for (index, bar) in bars.enumerated() where bar.peak > 0.01 {
            let x = plot.minX + slotWidth * CGFloat(index) + (slotWidth - barWidth) / 2
            let height = plot.height * bar.height
            columns.addRect(CGRect(x: x, y: plot.maxY - height, width: barWidth, height: height))
            let peakY = plot.maxY - plot.height * bar.peak
            caps.addRect(CGRect(x: x, y: peakY - 2, width: barWidth, height: 2))
        }

        context.fill(columns, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.29, green: 0.92, blue: 0.33), location: 0),
                .init(color: Color(red: 1, green: 0.85, blue: 0.22), location: 0.62),
                .init(color: Color(red: 1, green: 0.27, blue: 0.20), location: 1)
            ]),
            startPoint: CGPoint(x: plot.minX, y: plot.maxY),
            endPoint: CGPoint(x: plot.minX, y: plot.minY)
        ))
        context.fill(caps, with: .color(Color(red: 1, green: 0.94, blue: 0.73)))
    }
}

private struct SpectrumBar: Equatable {
    private(set) var height = 0.0
    private(set) var peak = 0.0
    private var holdRemaining = 0.0

    mutating func update(decibels: Float, decay: Double, elapsed: Double) {
        let target = min(1, max(0, (Double(decibels) + 70) / 70))
        height = max(target, height * decay)

        if target > 0, target >= peak {
            peak = target
            holdRemaining = 0.32
        } else {
            let fallingTime = max(0, elapsed - holdRemaining)
            holdRemaining = max(0, holdRemaining - elapsed)
            peak = max(height, peak - 0.75 * fallingTime)
        }
    }
}
