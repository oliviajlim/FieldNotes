import MetalKit
import SwiftUI

struct RetroVisualizerView: View {
    let samples: OscilloscopeSamples
    let isActive: Bool
    let sourceLabel: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        RetroMetalSurface(
            samples: samples,
            isRunning: isActive && scenePhase == .active && isVisible,
            reduceMotion: reduceMotion
        )
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 8))
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Retro audio visualizer")
        .accessibilityValue(sourceLabel)
    }
}

private struct RetroMetalSurface: UIViewRepresentable {
    let samples: OscilloscopeSamples
    let isRunning: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> UIView {
        guard let renderer = RetroVisualizerRenderer(samples: samples) else {
            let label = UILabel()
            label.text = String(localized: "Retro visualizer unavailable")
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.backgroundColor = .black
            return label
        }

        let view = RetroMetalView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.colorPixelFormat = RetroVisualizerRenderer.displayFormat
        view.backgroundColor = .black
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? RetroMetalView, let renderer = view.renderer else { return }

        let changed = renderer.samples !== samples || renderer.reduceMotion != reduceMotion || renderer.isRunning != isRunning
        renderer.samples = samples
        renderer.reduceMotion = reduceMotion
        renderer.isRunning = isRunning
        if changed { renderer.reset() }

        view.preferredFramesPerSecond = reduceMotion ? 10 : 30
        view.enableSetNeedsDisplay = !isRunning
        view.isPaused = !isRunning
        if !isRunning { view.setNeedsDisplay() }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        guard let view = uiView as? RetroMetalView else { return }
        view.isPaused = true
        view.renderer = nil
    }
}

private final class RetroMetalView: MTKView {
    var renderer: RetroVisualizerRenderer?

    override func draw(_ rect: CGRect) {
        renderer?.draw(in: self)
    }
}
