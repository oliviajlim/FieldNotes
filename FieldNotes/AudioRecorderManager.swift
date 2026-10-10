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

    var isRecording: Bool {
        activeRecordingNoteID != nil
    }

    func requestMicrophonePermissions() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        print("granted \(granted)")
        self.permissionStatus = granted ? .granted : .denied
        return granted
    }

    func startRecording(id: UUID) {
        guard !isRecording else {
            print("already recording")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            /*
             • audioEngine.inputNode is the microphone's spot in the engine's plumbing. You don't create it; the engine already has one.
             • outputFormat asks what comes out of this node. Audio comes out of the mic node and flows toward your tap, so you want output.
             • forBus: 0 needs a word you haven't met: a bus is a numbered connection socket on a node. The mic node has one output socket, number 0.
             */
            print("Mic format: \(format)")

            try createFile(noteID: id, micFormat: format)
            activeRecordingNoteID = id
//            writeToFile()
        } catch {
            print("error: \(error)")
        }
    }

    func createFile(noteID: UUID, micFormat: AVAudioFormat) throws {
        let folderURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Recordings")

        // ApplicationSupport/Recordings

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true) // Actually creates the folder

        let fileURL = folderURL.appending(path: "\(noteID.uuidString).m4a")

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
            // 1. write `buffer` into `file`
            // 2. print buffer.frameLength (temporary, to see it working)
        }
    }

    func closeFile() {
        
    }

    func stopRecording() {

        closeFile()
        // trim audio

        self.activeRecordingNoteID = nil
        // should save the audio file locally

    }
}
