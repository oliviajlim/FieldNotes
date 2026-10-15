//
//  AudioRecorderManager.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/1/26.
//

import Observation
import AVFAudio

@Observable
final class AudioRecorderManager {
    var permissionStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    var activeRecordingNoteID: UUID? = nil
    private let audioEngine = AVAudioEngine()
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?

    private(set) var activePlaybackNoteID: UUID? = nil
    private(set) var isPaused = false
    private let playerNode = AVAudioPlayerNode()
    /// Bumped on every play/stop so a completion from an earlier playback is ignored.
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
    private static func recordingsFolderURL() throws -> URL {
        let folderURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Recordings")

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true) // Actually creates the folder
        return folderURL
    }

    // MARK: - Recording

    func startRecording(id: UUID) {
        guard !isRecording else {
            print("already recording")
            return
        }

        // Only one recording or playback at a time.
        stopPlayback()

        do {
            try activateSession()

            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            /*
             • audioEngine.inputNode is the microphone's spot in the engine's plumbing. You don't create it; the engine already has one.
             • outputFormat asks what comes out of this node. Audio comes out of the mic node and flows toward your tap, so you want output.
             • forBus: 0 needs a word you haven't met: a bus is a numbered connection socket on a node. The mic node has one output socket, number 0.
             */
            print("Mic format: \(format)")

            try createFile(noteID: id, micFormat: format)
            guard let recordingFile else {
                cleanUpFailedRecording()
                return
            }

            Self.installTap(on: audioEngine.inputNode, format: format, file: recordingFile)
            audioEngine.prepare()
            try audioEngine.start()

            // Only mark the note as recording once audio is actually flowing.
            activeRecordingNoteID = id
        } catch {
            print("error: \(error)")
            cleanUpFailedRecording()
        }
    }

    /// Undoes a partial start so no tap, empty file, or active session is left behind.
    private func cleanUpFailedRecording() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recordingFile = nil

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil

        deactivateSession()
    }

    func createFile(noteID: UUID, micFormat: AVAudioFormat) throws {
        let fileURL = try Self.recordingsFolderURL().appending(path: "\(noteID.uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,   // on disk: compress to AAC (.m4a)
            AVSampleRateKey: micFormat.sampleRate,                 // samples per second
            AVNumberOfChannelsKey: micFormat.channelCount            // how many channels
        ]

        recordingFile = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: micFormat.commonFormat,        // the kind of numbers in the buffers (the "Float32" part)
            interleaved: micFormat.isInterleaved       // how channels are arranged in the buffers
        )
        recordingURL = fileURL

        print(fileURL)
        print(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    /// nonisolated: the tap closure runs on the audio thread, not the main thread.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        file: AVAudioFile
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // ← runs ~10×/second on the AUDIO thread
            do {
                try file.write(from: buffer)
            } catch {
                print("write failed: \(error)")
            }
        }
    }

    func closeFile() {
        recordingFile?.close()   // finalizes the .m4a so it's playable
        recordingFile = nil
    }

    /// Stops recording and returns the saved file's name, or nil if nothing was recording.
    func stopRecording() -> String? {
        guard isRecording, let recordingURL else { return nil }

        // Order matters: stop the flow of buffers before sealing the file.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        closeFile()
        deactivateSession()

        activeRecordingNoteID = nil
        self.recordingURL = nil
        return recordingURL.lastPathComponent
    }

    // MARK: - Playback

    /// Plays a saved recording, or resumes it if this note is paused.
    func play(fileName: String, noteID: UUID) {
        guard !isRecording else { return }

        if activePlaybackNoteID == noteID, isPaused {
            playerNode.play()
            isPaused = false
            return
        }

        // A different note may be playing; stop it first.
        stopPlayback()

        do {
            try activateSession()

            // Rebuild the full URL from the filename stored in Core Data.
            let url = try Self.recordingsFolderURL().appending(path: fileName)
            let file = try AVAudioFile(forReading: url)

            // file → playerNode → mainMixerNode → outputNode (speaker)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: file.processingFormat)

            playbackGeneration += 1
            let generation = playbackGeneration
            Self.schedule(file, on: playerNode) { [weak self] in
                self?.playbackFinished(generation: generation)
            }

            audioEngine.prepare()
            try audioEngine.start()
            playerNode.play()

            activePlaybackNoteID = noteID
            isPaused = false
        } catch {
            print("playback error: \(error)")
            stopPlayback()
        }
    }

    func pausePlayback() {
        guard activePlaybackNoteID != nil, !isPaused else { return }
        playerNode.pause()
        isPaused = true
    }

    func stopPlayback() {
        guard activePlaybackNoteID != nil else { return }

        // stop() fires the scheduled completion; bumping the generation makes it a no-op.
        playbackGeneration += 1
        playerNode.stop()
        audioEngine.stop()
        deactivateSession()

        activePlaybackNoteID = nil
        isPaused = false
    }

    private func playbackFinished(generation: Int) {
        guard generation == playbackGeneration else { return }
        stopPlayback()
    }

    /// nonisolated: the completion runs on an audio thread, so it hops back to the main actor.
    private nonisolated static func schedule(
        _ file: AVAudioFile,
        on player: AVAudioPlayerNode,
        onFinished: @escaping @MainActor @Sendable () -> Void
    ) {
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in
                onFinished()
            }
        }
    }
}
