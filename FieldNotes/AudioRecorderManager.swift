//
//  AudioRecorderManager.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/1/26.
//

import Observation
import AVFAudio
import Synchronization

@Observable
final class AudioRecorderManager {
    enum RecordingError: Error {
        case microphoneUnavailable
        case unusableTake
    }

    private nonisolated struct Playback {
        let noteID: UUID
        let file: AVAudioFile
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
        var startFrame: AVAudioFramePosition = 0
        var pausedPosition: TimeInterval?

        var duration: TimeInterval { Double(frameCount) / sampleRate }
        var startPosition: TimeInterval { Double(startFrame) / sampleRate }
    }

    private enum PlaybackError: Error {
        case emptyFile
    }

    var permissionStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    private(set) var activeRecordingNoteID: UUID? = nil
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recordingTake: RecordingTake?

    let oscilloscopeSamples = OscilloscopeSamples()
    @ObservationIgnored private var hasPlaybackTap = false

    private var playback: Playback?
    private var playbackRequest: (id: UUID, noteID: UUID)?
    var activePlaybackNoteID: UUID? { playback?.noteID }
    var loadingPlaybackNoteID: UUID? { playbackRequest?.noteID }
    var isPaused: Bool { playback?.pausedPosition != nil }
    private let playerNode = AVAudioPlayerNode()
    /// A seek stops the previous segment, which can still call its completion handler.
    @ObservationIgnored private var playbackGeneration = 0

    var isRecording: Bool {
        activeRecordingNoteID != nil
    }

    init() {
        // Attach once: the player node stays in the engine for the app's lifetime.
        audioEngine.attach(playerNode)
    }

    func requestMicrophonePermissions() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        print("granted \(granted)")
        self.permissionStatus = granted ? .granted : .denied
        return granted
    }

    // MARK: - Session

    /// .defaultToSpeaker: .playAndRecord otherwise plays through the quiet earpiece.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("error deactivating session: \(error)")
        }
    }

    // MARK: - Files

    /// Application Support/Recordings, created if it doesn't exist yet.
    private nonisolated static func recordingsFolderURL() throws -> URL {
        let folderURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Recordings")

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true) // Actually creates the folder
        return folderURL
    }

    private static func newRecordingURL(noteID: UUID) throws -> URL {
        try recordingsFolderURL().appending(path: "\(noteID.uuidString)-\(UUID().uuidString).m4a")
    }

    static func importRecording(from source: URL, noteID: UUID) throws -> String {
        let destination = try newRecordingURL(noteID: noteID)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination.lastPathComponent
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Recording

    func startRecording(id: UUID) throws {
        guard !isRecording else { return }

        // Each take has its own file so a retake cannot overwrite a saved one.
        let url = try Self.newRecordingURL(noteID: id)

        // Only one recording or playback at a time.
        stopPlayback()

        do {
            try activateSession()

            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecordingError.microphoneUnavailable
            }

            let take = try RecordingTake(url: url, format: format)
            recordingTake = take
            oscilloscopeSamples.clear()
            Self.installTap(on: audioEngine.inputNode, format: format, take: take, samples: oscilloscopeSamples)
            audioEngine.prepare()
            try audioEngine.start()

            // Only mark the note as recording once audio is actually flowing.
            activeRecordingNoteID = id
        } catch {
            if recordingTake != nil {
                _ = finishRecording()
            } else {
                deactivateSession()
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// nonisolated: the tap closure runs on the audio thread, not the main thread.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        take: RecordingTake,
        samples: OscilloscopeSamples
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // The audio thread delivers PCM; the requested size is a hint to the engine.
            samples.capture(buffer)
            take.write(buffer)
        }
    }

    /// Returns a finalized take that the caller can link to the note.
    func stopRecording() throws -> String? {
        guard let take = finishRecording() else { return nil }
        guard take.isUsable else {
            try? FileManager.default.removeItem(at: take.url)
            throw RecordingError.unusableTake
        }
        return take.url.lastPathComponent
    }

    func discardRecording() {
        guard let take = finishRecording() else { return }
        try? FileManager.default.removeItem(at: take.url)
    }

    static func deleteRecording(fileName: String) {
        guard let url = try? recordingsFolderURL().appending(path: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func finishRecording() -> (url: URL, isUsable: Bool)? {
        guard let recordingTake else { return nil }

        // Order matters: stop the flow of buffers before sealing the file.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let isUsable = recordingTake.finish()
        deactivateSession()

        self.recordingTake = nil
        activeRecordingNoteID = nil
        oscilloscopeSamples.clear()
        return (recordingTake.url, isUsable)
    }

    // MARK: - Playback

    @concurrent nonisolated static func duration(fileName: String) async -> TimeInterval? {
        guard let url = try? recordingsFolderURL().appending(path: fileName),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let frames = file.length
        return rate > 0 && frames > 0 ? Double(frames) / rate : nil
    }

    /// Plays a saved recording, or resumes it if this note is paused.
    func play(fileName: String, noteID: UUID, from position: TimeInterval = 0) async throws {
        guard !isRecording, playbackRequest == nil else { return }

        if var current = playback, current.noteID == noteID, current.pausedPosition != nil {
            if current.startFrame == current.frameCount {
                schedulePlayback(current, at: 0, shouldPlay: true)
            } else {
                playerNode.play()
                current.pausedPosition = nil
                playback = current
            }
            return
        }

        // A different note may be playing; stop it first.
        stopPlayback()
        let requestID = UUID()
        playbackRequest = (requestID, noteID)
        defer {
            if playbackRequest?.id == requestID { playbackRequest = nil }
        }

        do {
            let current = try await Self.openPlayback(fileName: fileName, noteID: noteID)
            try Task.checkCancellation()
            guard playbackRequest?.id == requestID else { return }

            try activateSession()

            // file → playerNode → mainMixerNode → outputNode (speaker)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: current.file.processingFormat)

            Self.installPlaybackTap(on: audioEngine.mainMixerNode, samples: oscilloscopeSamples)
            hasPlaybackTap = true

            audioEngine.prepare()
            try audioEngine.start()
            schedulePlayback(current, at: position >= current.duration ? 0 : position, shouldPlay: true)
        } catch {
            guard playbackRequest?.id == requestID else { return }
            stopPlayback()
            throw error
        }
    }

    @concurrent private nonisolated static func openPlayback(fileName: String, noteID: UUID) async throws -> sending Playback {
        let url = try recordingsFolderURL().appending(path: fileName)
        let file = try AVAudioFile(forReading: url)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        guard frameCount > 0, sampleRate > 0 else { throw PlaybackError.emptyFile }
        return Playback(noteID: noteID, file: file, frameCount: frameCount, sampleRate: sampleRate)
    }

    func playbackPosition(for noteID: UUID) -> TimeInterval? {
        guard let current = playback, current.noteID == noteID else { return nil }
        if let pausedPosition = current.pausedPosition { return pausedPosition }

        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0 else { return current.startPosition }

        let elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        return min(current.duration, current.startPosition + elapsed)
    }

    func seek(to position: TimeInterval, noteID: UUID) {
        guard let current = playback, current.noteID == noteID, position.isFinite else { return }
        schedulePlayback(current, at: position, shouldPlay: current.pausedPosition == nil)
    }

    private func schedulePlayback(_ current: Playback, at position: TimeInterval, shouldPlay: Bool) {
        playbackGeneration += 1
        let generation = playbackGeneration
        playerNode.stop()
        oscilloscopeSamples.clear()

        var segment = current
        let seconds = position.isFinite ? max(0, position) : 0
        segment.startFrame = seconds >= segment.duration
            ? segment.frameCount
            : AVAudioFramePosition(seconds * segment.sampleRate)
        let hasFrames = segment.startFrame < segment.frameCount
        segment.pausedPosition = shouldPlay && hasFrames ? nil : segment.startPosition
        playback = segment

        guard hasFrames else { return }
        Self.schedule(segment.file, from: segment.startFrame, to: segment.frameCount, on: playerNode) { [weak self] in
            self?.playbackFinished(generation: generation)
        }
        if shouldPlay { playerNode.play() }
    }

    func pausePlayback() {
        guard let current = playback, current.pausedPosition == nil else { return }
        let position = playbackPosition(for: current.noteID) ?? current.startPosition
        playerNode.pause()
        playback?.pausedPosition = position
    }

    func stopPlayback() {
        playbackRequest = nil
        // The tap may exist even if engine.start() failed before setting the ID.
        guard activePlaybackNoteID != nil || hasPlaybackTap else { return }

        // stop() fires the scheduled completion; bumping the generation makes it a no-op.
        playbackGeneration += 1
        playerNode.stop()
        audioEngine.stop()
        if hasPlaybackTap {
            audioEngine.mainMixerNode.removeTap(onBus: 0)
            hasPlaybackTap = false
        }
        oscilloscopeSamples.clear()
        deactivateSession()

        playback = nil
    }

    private func playbackFinished(generation: Int) {
        guard generation == playbackGeneration else { return }
        stopPlayback()
    }

    private nonisolated static func installPlaybackTap(on mixer: AVAudioMixerNode, samples: OscilloscopeSamples) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            samples.capture(buffer)
        }
    }

    /// nonisolated: the completion runs on an audio thread, so it hops back to the main actor.
    private nonisolated static func schedule(
        _ file: AVAudioFile,
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        on player: AVAudioPlayerNode,
        onFinished: @escaping @MainActor @Sendable () -> Void
    ) {
        // AVAudioFrameCount is narrower than the file's frame positions.
        let maximumSegmentLength = AVAudioFramePosition(AVAudioFrameCount.max)
        var nextFrame = startFrame
        while endFrame - nextFrame > maximumSegmentLength {
            player.scheduleSegment(file, startingFrame: nextFrame, frameCount: .max, at: nil, completionHandler: nil)
            nextFrame += maximumSegmentLength
        }
        player.scheduleSegment(
            file,
            startingFrame: nextFrame,
            frameCount: AVAudioFrameCount(endFrame - nextFrame),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { _ in
            Task { @MainActor in
                onFinished()
            }
        }
    }
}

/// Serializes file writes with finalization if the last tap callback is still in flight.
private nonisolated final class RecordingTake: Sendable {
    private struct State {
        var file: AVAudioFile?
        var writeFailed = false
    }

    let url: URL
    private let state: Mutex<State>

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        state = Mutex(State(file: file))
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        state.withLock { state in
            guard let file = state.file, !state.writeFailed else { return }
            do {
                try file.write(from: buffer)
            } catch {
                state.writeFailed = true
                print("Audio write failed: \(error)")
            }
        }
    }

    func finish() -> Bool {
        state.withLock { state in
            guard let file = state.file else { return false }
            let isUsable = file.framePosition > 0 && !state.writeFailed
            file.close()
            state.file = nil
            return isUsable
        }
    }
}
