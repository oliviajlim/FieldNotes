import AVFAudio
import Synchronization

/// A bounded handoff between the audio callback and the display.
/// This type is nonisolated because the app otherwise defaults to MainActor.
nonisolated final class OscilloscopeSamples: Sendable {
    static let historyCapacity = 12
    static let samplesPerFrame = 1024

    nonisolated struct Snapshot: Sendable {
        static let empty = Snapshot(frames: [], sampleRate: 0, sourceGeneration: 0)

        let frames: [[Float]]
        let sampleRate: Double
        let sourceGeneration: UInt64

        var samples: [Float] { frames.last ?? [] }

        var duration: Double {
            sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        }
    }

    private struct Storage: Sendable {
        var samples = [Float](repeating: 0, count: historyCapacity * samplesPerFrame)
        var frameLengths = [Int](repeating: 0, count: historyCapacity)
        var nextSlot = 0
        var frameCount = 0
        var sampleRate = 0.0
        var sourceGeneration: UInt64 = 0
    }

    private let storage = Mutex(Storage())

    func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }

        // Skip a visual frame if the display is reading. Never wait on the UI.
        storage.withLockIfAvailable { storage in
            let sampleRate = buffer.format.sampleRate
            if storage.sampleRate != sampleRate {
                storage.nextSlot = 0
                storage.frameCount = 0
                storage.sampleRate = sampleRate
                storage.sourceGeneration &+= 1
            }

            let count = min(Int(buffer.frameLength), Self.samplesPerFrame)
            let start = Int(buffer.frameLength) - count
            let channel = channels[0]
            let stride = buffer.stride
            let base = storage.nextSlot * Self.samplesPerFrame

            // Keep the most recent signed samples of channel 1 (left for stereo).
            // Respect stride so interleaved and noninterleaved Float32 both work.
            for index in 0..<count {
                storage.samples[base + index] = channel[(start + index) * stride]
            }
            storage.frameLengths[storage.nextSlot] = count
            storage.nextSlot = (storage.nextSlot + 1) % Self.historyCapacity
            storage.frameCount = min(storage.frameCount + 1, Self.historyCapacity)
        }
    }

    func snapshot(includeHistory: Bool = false) -> Snapshot {
        storage.withLock { storage in
            let count = includeHistory ? storage.frameCount : min(storage.frameCount, 1)
            let oldestSlot = (storage.nextSlot + Self.historyCapacity - count) % Self.historyCapacity

            // Copy on the display side so the tap can keep reusing its storage.
            let frames = storage.samples.withUnsafeBufferPointer { pointer in
                (0..<count).map { index in
                    let slot = (oldestSlot + index) % Self.historyCapacity
                    let start = pointer.baseAddress?.advanced(by: slot * Self.samplesPerFrame)
                    return Array(UnsafeBufferPointer(start: start, count: storage.frameLengths[slot]))
                }
            }
            return Snapshot(frames: frames, sampleRate: storage.sampleRate, sourceGeneration: storage.sourceGeneration)
        }
    }

    func clear() {
        storage.withLock { storage in
            storage.nextSlot = 0
            storage.frameCount = 0
            storage.sampleRate = 0
            storage.sourceGeneration &+= 1
        }
    }
}
