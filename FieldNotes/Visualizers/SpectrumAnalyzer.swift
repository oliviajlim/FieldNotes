import Accelerate

/// The FFT and band mapping run on the display side of the audio sample handoff.
nonisolated final class SpectrumAnalyzer {
    static let frameSize = OscilloscopeSamples.samplesPerFrame
    static let binCount = frameSize / 2
    static let bandCount = 32

    private let fft: FFTSetup
    private let log2Size = vDSP_Length(frameSize.trailingZeroBitCount)
    private var real = [Float](repeating: 0, count: binCount)
    private var imaginary = [Float](repeating: 0, count: binCount)
    private var window: [Float] = []
    private var windowSum: Float = 0
    private var mappedSampleRate = 0.0
    private var bandRanges: [Range<Int>] = []

    init?() {
        guard let fft = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        self.fft = fft
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// One-sided dBFS values in order from bin 1 through Nyquist. DC is excluded.
    func decibels(for input: [Float]) -> [Float] {
        let samples = input.suffix(Self.frameSize)
        guard samples.count >= 4 else { return [] }
        if window.count != samples.count {
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: samples.count, isHalfWindow: false)
            windowSum = vDSP.sum(window)
        }

        // Remove DC before windowing so a constant offset doesn't leak into the bass bars.
        let mean = vDSP.mean(samples)
        for index in real.indices {
            let even = index * 2
            let odd = even + 1
            real[index] = even < samples.count ? (samples[samples.startIndex + even] - mean) * window[even] : 0
            imaginary[index] = odd < samples.count ? (samples[samples.startIndex + odd] - mean) * window[odd] : 0
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var packed = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zrip(fft, &packed, 1, log2Size, FFTDirection(kFFTDirection_Forward))
            }
        }

        // The forward real FFT scales by two. Interior bins also represent a
        // pair of mirrored frequencies, so only the packed Nyquist bin needs / 2.
        var result = (1..<Self.binCount).map { index in
            Self.decibels(amplitude: hypotf(real[index], imaginary[index]) / windowSum)
        }
        result.append(Self.decibels(amplitude: abs(imaginary[0]) / (2 * windowSum)))
        return result
    }

    func bandDecibels(for samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate >= 40 else { return [] }
        if mappedSampleRate != sampleRate {
            bandRanges = Self.logarithmicBands(sampleRate: sampleRate)
            mappedSampleRate = sampleRate
        }

        let bins = decibels(for: samples)
        guard !bins.isEmpty else { return [] }
        return bandRanges.map { bins[$0].max() ?? -.infinity }
    }

    private static func logarithmicBands(sampleRate: Double) -> [Range<Int>] {
        let binWidth = sampleRate / Double(frameSize)
        let firstBin = max(1, Int((20 / binWidth).rounded(.up)))
        let endBin = binCount + 1
        let count = min(bandCount, endBin - firstBin)
        let ratio = Double(endBin) / Double(firstBin)
        var start = firstBin

        return (1...count).map { band in
            let idealEdge = Double(firstBin) * pow(ratio, Double(band) / Double(count))
            // Quantize the edges and keep at least one bin in every band, including in the bass.
            let end = min(endBin - (count - band), max(start + 1, Int(idealEdge.rounded())))
            defer { start = end }
            return (start - 1)..<(end - 1)
        }
    }

    private static func decibels(amplitude: Float) -> Float {
        guard amplitude.isFinite else { return -.infinity }
        return 20 * log10f(max(amplitude, 1e-8))
    }
}
