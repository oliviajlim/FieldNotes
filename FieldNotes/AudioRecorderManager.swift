//
//  AudioRecorderManager.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/1/26.
//

import Observation
import AVFAudio
import AVFoundation
import Combine
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

    private struct VideoPlayback {
        let noteID: UUID
        let player: AVPlayer
        let duration: CMTime
        let samples: OscilloscopeSamples
        var isPaused = false
        var pendingSeek: (id: UUID, time: CMTime)?

        var position: CMTime { pendingSeek?.time ?? player.currentTime() }
    }

    var permissionStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    private(set) var activeRecordingNoteID: UUID? = nil
    private(set) var isStartingRecording = false
    private let audioEngine = AVAudioEngine()
    private let audioSession = AudioSessionTransitions()
    @ObservationIgnored private var recordingTake: RecordingTake?

    private let audioSamples = OscilloscopeSamples()
    var oscilloscopeSamples: OscilloscopeSamples { videoPlayback?.samples ?? audioSamples }
    @ObservationIgnored private var hasPlaybackTap = false

    private var playback: Playback?
    private var videoPlayback: VideoPlayback?
    @ObservationIgnored private var videoEndObserver: AnyCancellable?
    @ObservationIgnored private var videoTimeObserver: Any?
    private var playbackRequest: (id: UUID, noteID: UUID, isVideo: Bool)?
    @ObservationIgnored private var playbackSessionRequested = false
    var activePlaybackNoteID: UUID? { videoPlayback?.noteID ?? playback?.noteID }
    var loadingPlaybackNoteID: UUID? { playbackRequest?.noteID }
    var isPaused: Bool { videoPlayback?.isPaused ?? (playback?.pausedPosition != nil) }
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

    private func activatePlaybackSession(_ mode: AudioSessionTransitions.Mode) async throws {
        playbackSessionRequested = true
        try await audioSession.activate(mode)
        try Task.checkCancellation()
    }

    private func releasePlaybackSession() {
        guard playbackSessionRequested else { return }
        playbackSessionRequested = false
        audioSession.deactivate()
    }

    func prepareForVideoCapture() async {
        stopPlayback()
        await audioSession.waitForPendingOperations()
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

    func startRecording(id: UUID) async throws {
        guard !isRecording, !isStartingRecording else { return }
        try Task.checkCancellation()

        // Each take has its own file so a retake cannot overwrite a saved one.
        let url = try Self.newRecordingURL(noteID: id)

        // Only one recording or playback at a time.
        isStartingRecording = true
        defer { isStartingRecording = false }
        stopPlayback()

        do {
            try await audioSession.activate(.audio)
            try Task.checkCancellation()

            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecordingError.microphoneUnavailable
            }

            let take = try RecordingTake(url: url, format: format)
            recordingTake = take
            audioSamples.clear()
            Self.installTap(on: audioEngine.inputNode, format: format, take: take, samples: audioSamples)
            audioEngine.prepare()
            try audioEngine.start()

            // Only mark the note as recording once audio is actually flowing.
            activeRecordingNoteID = id
        } catch {
            if recordingTake != nil {
                _ = finishRecording()
            } else {
                audioSession.deactivate()
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
        audioSession.deactivate()

        self.recordingTake = nil
        activeRecordingNoteID = nil
        audioSamples.clear()
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

    /// Plays or resumes either kind of note through the same transport controls.
    func play(fileName: String?, videoFileName: String? = nil, noteID: UUID, from position: TimeInterval = 0) async throws {
        guard !isRecording, !isStartingRecording, playbackRequest == nil else { return }

        if let current = videoPlayback, current.noteID == noteID, current.isPaused {
            if current.position >= current.duration {
                seekVideo(to: .zero, player: current.player)
            }
            videoPlayback?.isPaused = false
            current.player.play()
            return
        }

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
        playbackRequest = (requestID, noteID, videoFileName != nil)
        defer {
            if playbackRequest?.id == requestID { playbackRequest = nil }
        }

        do {
            if let videoFileName {
                try await openVideoPlayback(fileName: videoFileName, audioFileName: fileName, noteID: noteID,
                                            from: position, requestID: requestID)
                return
            }
            guard let fileName else { throw PlaybackError.emptyFile }
            let current = try await Self.openPlayback(fileName: fileName, noteID: noteID)
            try Task.checkCancellation()
            guard playbackRequest?.id == requestID else { return }

            try await activatePlaybackSession(.audio)
            guard playbackRequest?.id == requestID else { return }

            // file → playerNode → mainMixerNode → outputNode (speaker)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: current.file.processingFormat)

            Self.installPlaybackTap(on: audioEngine.mainMixerNode, samples: audioSamples)
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
        if let current = videoPlayback, current.noteID == noteID {
            let time = current.position
            return time.isNumeric ? time.seconds : 0
        }
        guard let current = playback, current.noteID == noteID else { return nil }
        if let pausedPosition = current.pausedPosition { return pausedPosition }

        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0 else { return current.startPosition }

        let elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        return min(current.duration, current.startPosition + elapsed)
    }

    func seek(to position: TimeInterval, noteID: UUID) {
        guard position.isFinite else { return }
        if let current = videoPlayback, current.noteID == noteID {
            current.samples.clear()
            let time = position >= current.duration.seconds ? current.duration : Self.videoTime(position)
            if time == current.duration {
                current.player.pause()
                videoPlayback?.isPaused = true
            }
            seekVideo(to: time, player: current.player)
            return
        }
        guard let current = playback, current.noteID == noteID else { return }
        schedulePlayback(current, at: position, shouldPlay: current.pausedPosition == nil)
    }

    private func schedulePlayback(_ current: Playback, at position: TimeInterval, shouldPlay: Bool) {
        playbackGeneration += 1
        let generation = playbackGeneration
        playerNode.stop()
        audioSamples.clear()

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
        if let current = videoPlayback, !current.isPaused {
            current.player.pause()
            videoPlayback?.isPaused = true
            return
        }
        guard let current = playback, current.pausedPosition == nil else { return }
        let position = playbackPosition(for: current.noteID) ?? current.startPosition
        playerNode.pause()
        playback?.pausedPosition = position
    }

    func stopPlayback() {
        stopVideoPlayback()
        playbackRequest = nil
        // The tap may exist even if engine.start() failed before setting the ID.
        if playback != nil || hasPlaybackTap {
            // stop() fires the scheduled completion; bumping the generation makes it a no-op.
            playbackGeneration += 1
            playerNode.stop()
            audioEngine.stop()
            if hasPlaybackTap {
                audioEngine.mainMixerNode.removeTap(onBus: 0)
                hasPlaybackTap = false
            }
            audioSamples.clear()
            playback = nil
        }
        releasePlaybackSession()
    }

    func videoPlayer(for noteID: UUID) -> AVPlayer? {
        guard videoPlayback?.noteID == noteID else { return nil }
        return videoPlayback?.player
    }

    private func openVideoPlayback(fileName: String, audioFileName: String?, noteID: UUID,
                                   from position: TimeInterval, requestID: UUID) async throws {
        let url = try VideoStore.fileURL(for: fileName)
        let audioURL = try audioFileName.map { try Self.recordingsFolderURL().appending(path: $0) }
        let samples = OscilloscopeSamples()
        let (item, duration, waveform) = try await NoteVideoPlayback.load(videoURL: url, audioURL: audioURL)
        try Task.checkCancellation()
        guard playbackRequest?.id == requestID else { return }

        try await activatePlaybackSession(.video)
        guard playbackRequest?.id == requestID else { return }

        let player = AVPlayer(playerItem: item)
        videoPlayback = VideoPlayback(noteID: noteID, player: player, duration: duration, samples: samples)
        if let waveform {
            videoTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
                @Sendable [weak self, weak player] time in
                MainActor.assumeIsolated {
                    guard let player, let current = self?.videoPlayback, current.player === player,
                          !current.isPaused, current.pendingSeek == nil else { return }
                    waveform.capture(at: time, into: samples)
                }
            }
        }
        videoEndObserver = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] _ in
                guard let player, let current = self?.videoPlayback, current.player === player,
                      !current.isPaused, current.position.seconds >= duration.seconds - 0.05 else { return }
                self?.stopVideoPlayback(for: noteID)
            }
        if position.isFinite, position > 0, position < duration.seconds {
            seekVideo(to: Self.videoTime(position), player: player)
        }
        player.play()
    }

    private func seekVideo(to time: CMTime, player: AVPlayer) {
        let id = UUID()
        videoPlayback?.pendingSeek = (id, time)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.videoPlayback?.pendingSeek?.id == id else { return }
                self.videoPlayback?.pendingSeek = nil
            }
        }
    }

    func stopVideoPlayback(for noteID: UUID? = nil) {
        if let request = playbackRequest, request.isVideo, noteID == nil || request.noteID == noteID {
            playbackRequest = nil
            // A dismissed card may still be waiting for session activation.
            if videoPlayback == nil { releasePlaybackSession() }
        }
        guard let videoPlayback, noteID == nil || videoPlayback.noteID == noteID else { return }
        videoEndObserver = nil
        if let videoTimeObserver {
            videoPlayback.player.removeTimeObserver(videoTimeObserver)
            self.videoTimeObserver = nil
        }
        videoPlayback.player.pause()
        videoPlayback.player.replaceCurrentItem(with: nil)
        self.videoPlayback = nil
        releasePlaybackSession()
    }

    private static func videoTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 60_000)
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
