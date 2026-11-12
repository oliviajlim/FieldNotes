import AVFoundation

/// Short video notes have a bounded soundtrack. Decode it once and use the
/// player's media time to feed the same visualizers as a regular recording.
nonisolated struct VideoWaveform: Sendable {
    private static let sampleRate = 48_000.0
    private let pcm: [Float]

    @concurrent static func decode(asset: AVAsset, duration: CMTime) async throws -> VideoWaveform? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let seconds = min(duration.seconds, Double(VideoImport.maximumDurationSeconds))
        let frameCount = Int((seconds * sampleRate).rounded(.up))
        var pcm = [Float](repeating: 0, count: frameCount)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { return nil }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }

        var copiedFrames = false
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            let time = sample.presentationTimeStamp
            guard time.isNumeric else { continue }
            let start = Int((time.seconds * sampleRate).rounded())
            try sample.withUnsafeSampleBuffer { buffer in
                try buffer.withAudioBufferList { list, _ in
                    guard let channel = list.first, let data = channel.mData else { return }
                    let inputCount = min(buffer.numSamples, Int(channel.mDataByteSize) / MemoryLayout<Float>.stride)
                    let offset = max(0, -start)
                    let destination = max(0, start)
                    let count = min(inputCount - offset, frameCount - destination)
                    guard count > 0 else { return }
                    pcm.withUnsafeMutableBufferPointer { pcm in
                        pcm.baseAddress!.advanced(by: destination).update(
                            from: data.assumingMemoryBound(to: Float.self).advanced(by: offset), count: count
                        )
                    }
                    copiedFrames = true
                }
            }
        }
        return copiedFrames ? VideoWaveform(pcm: pcm) : nil
    }

    func capture(at time: CMTime, into samples: OscilloscopeSamples) {
        guard time.isNumeric, time >= .zero else { return }
        let end = min(pcm.count, Int((time.seconds * Self.sampleRate).rounded()) + 1)
        let start = max(0, end - OscilloscopeSamples.samplesPerFrame)
        pcm.withUnsafeBufferPointer { pcm in
            guard let base = pcm.baseAddress else { return }
            samples.capture(base.advanced(by: start), frames: end - start, stride: 1, sampleRate: Self.sampleRate)
        }
    }
}
