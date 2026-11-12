import MetalKit

final class RetroVisualizerRenderer {
    static let displayFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private static let historyFormat: MTLPixelFormat = .rgba16Float

    // Keep this layout in sync with RetroFrame in RetroVisualizer.metal.
    private struct Frame {
        var time: Float = 0
        var aspect: Float = 1
        var level: Float = 0
        var bass: Float = 0
        var waveformCount: UInt32 = 0
        var hasHistory: UInt32 = 0
        var motion: Float = 1
        var frameStep: Float = 1
    }

    let device: MTLDevice
    var samples: OscilloscopeSamples
    var isRunning = false
    var reduceMotion = false

    private let queue: MTLCommandQueue
    private let feedbackPipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let spectrum = SpectrumAnalyzer()
    private var waveform = [Float](repeating: 0, count: 192)
    private var frame = Frame()
    private var sourceGeneration: UInt64?
    private var previousTime: CFTimeInterval?
    private var history: [MTLTexture] = []
    private var writeIndex = 0
    private var hasHistory = false

    init?(samples: OscilloscopeSamples) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "retroVertex") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = library.makeFunction(name: "retroFeedback")
        descriptor.colorAttachments[0].pixelFormat = Self.historyFormat
        guard let feedback = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        descriptor.fragmentFunction = library.makeFunction(name: "retroPresent")
        descriptor.colorAttachments[0].pixelFormat = Self.displayFormat
        guard let display = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.samples = samples
        self.queue = queue
        self.feedbackPipeline = feedback
        self.displayPipeline = display
    }

    func reset() {
        frame = Frame()
        sourceGeneration = nil
        previousTime = nil
        hasHistory = false
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              prepareHistory(for: size) else { return }

        let snapshot = isRunning ? samples.snapshot() : .empty
        if snapshot.sourceGeneration != sourceGeneration {
            reset()
            sourceGeneration = snapshot.sourceGeneration
        }
        updateFrame(from: snapshot, aspect: Float(size.width / size.height))

        // Read the last image while rendering into the other texture. The two
        // textures swap roles only after both passes have been encoded.
        let output = history[writeIndex]
        let feedbackPass = MTLRenderPassDescriptor()
        feedbackPass.colorAttachments[0].texture = output
        feedbackPass.colorAttachments[0].loadAction = .dontCare
        feedbackPass.colorAttachments[0].storeAction = .store
        guard let feedback = command.makeRenderCommandEncoder(descriptor: feedbackPass) else { return }
        feedback.setRenderPipelineState(feedbackPipeline)
        feedback.setFragmentTexture(history[1 - writeIndex], index: 0)
        feedback.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        waveform.withUnsafeBytes { bytes in
            feedback.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        feedback.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        feedback.endEncoding()

        guard let display = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        display.setRenderPipelineState(displayPipeline)
        display.setFragmentTexture(output, index: 0)
        display.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        display.endEncoding()
        command.present(drawable)
        command.commit()

        writeIndex = 1 - writeIndex
        hasHistory = isRunning
    }

    private func prepareHistory(for size: CGSize) -> Bool {
        // A small feedback texture keeps the blur soft and bounds GPU work on larger screens.
        let scale = min(1, 512 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        if let current = history.first, current.width == width, current.height == height { return true }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.historyFormat, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor) else { return false }
        history = [first, second]
        writeIndex = 0
        hasHistory = false
        return true
    }

    private func updateFrame(from snapshot: OscilloscopeSamples.Snapshot, aspect: Float) {
        let now = CACurrentMediaTime()
        let elapsed = previousTime.map { min(0.1, now - $0) } ?? (1.0 / 30)
        previousTime = isRunning ? now : nil
        frame.frameStep = Float(elapsed * 30)
        frame.time += isRunning && !reduceMotion ? Float(elapsed) : 0
        frame.aspect = aspect
        frame.motion = reduceMotion ? 0 : 1
        frame.hasHistory = hasHistory && !reduceMotion ? 1 : 0

        let input = snapshot.samples
        guard input.count >= 2 else {
            frame.level = 0
            frame.bass = 0
            frame.waveformCount = 0
            return
        }

        var sum: Float = 0
        var squares: Float = 0
        for value in input where value.isFinite {
            sum += value
            squares += value * value
        }
        let mean = sum / Float(input.count)
        let variance = max(0, squares / Float(input.count) - mean * mean)
        let level = Self.normalizedLevel(10 * log10f(max(1e-8, variance)))
        frame.level = max(level, frame.level * powf(0.79, frame.frameStep))

        let bins = spectrum?.decibels(for: input) ?? []
        let hzPerBin = snapshot.sampleRate / Double(SpectrumAnalyzer.frameSize)
        let bassBinCount = hzPerBin > 0 ? Int(min(Double(bins.count), 180 / hzPerBin)) : 0
        let bass = Self.normalizedLevel(bins.prefix(bassBinCount).max() ?? -.infinity)
        frame.bass = max(bass, frame.bass * powf(0.86, frame.frameStep))

        for index in waveform.indices {
            let value = input[index * (input.count - 1) / (waveform.count - 1)]
            waveform[index] = value.isFinite ? min(1, max(-1, (value - mean) * 3)) : 0
        }
        frame.waveformCount = UInt32(waveform.count)
    }

    private static func normalizedLevel(_ decibels: Float) -> Float {
        min(1, max(0, (decibels + 60) / 52))
    }
}
