import AVFAudio
import Foundation

@MainActor
final class AudioSessionTransitions {
    enum Mode: Sendable {
        case audio
        case video
    }

    private enum SessionError: Error {
        case activationFailed
        case deactivationFailed
    }

    private let queue = DispatchQueue(label: "FieldNotes.audio-session")
    private var pendingOperation: Task<Void, Never>?

    func activate(_ mode: Mode) async throws {
        try Task.checkCancellation()
        try await enqueue(mode).value
    }

    func deactivate() {
        enqueue(nil)
    }

    func waitForPendingOperations() async {
        await pendingOperation?.value
    }

    @discardableResult
    private func enqueue(_ mode: Mode?) -> Task<Void, Error> {
        // Queue in request order, including the time spent waiting for AVAudioSession.
        // A stale deactivation must finish before the next activation begins.
        let previous = pendingOperation
        let operation = Task {
            await previous?.value
            try await Self.transition(to: mode, on: queue)
        }
        pendingOperation = Task {
            if case .failure(let error) = await operation.result, mode == nil {
                print("Error deactivating audio session: \(error)")
            }
        }
        return operation
    }

    private nonisolated static func transition(to mode: Mode?, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    switch mode {
                    case .audio:
                        // Route .playAndRecord through the speaker when no other output is selected.
                        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    case .video:
                        try session.setCategory(.playback, mode: .moviePlayback)
                    case nil:
                        break
                    }

                    if #available(iOS 27.0, *) {
                        if mode != nil {
                            session.activate { activated, error in
                                complete(activated, error: error ?? SessionError.activationFailed, continuation: continuation)
                            }
                        } else {
                            session.deactivate(options: .notifyOthersOnDeactivation) { deactivated, error in
                                complete(deactivated, error: error ?? SessionError.deactivationFailed, continuation: continuation)
                            }
                        }
                    } else {
                        if mode != nil {
                            try session.setActive(true)
                        } else {
                            try session.setActive(false, options: .notifyOthersOnDeactivation)
                        }
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func complete(_ succeeded: Bool, error: Error, continuation: CheckedContinuation<Void, Error>) {
        if succeeded {
            continuation.resume()
        } else {
            continuation.resume(throwing: error)
        }
    }
}
