import AVFAudio
import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct VideoImport: Transferable {
    static let maximumDurationSeconds = 30

    struct Preview: Sendable {
        let image: CGImage
        let date: Date?
        let audio: TemporaryFile?
    }

    /// The draft owns its files, so cancellation and reselection release them too.
    final class TemporaryFile: Sendable {
        let url: URL

        init(fileExtension: String) {
            url = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension(fileExtension)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum ImportError: LocalizedError {
        case tooLong
        case unplayable
        case unusableAudio

        var errorDescription: String? {
            switch self {
            case .tooLong: "Videos must be \(VideoImport.maximumDurationSeconds) seconds or shorter. Trim the clip in Photos and try again."
            case .unplayable: "This video can't be played. Choose another clip."
            case .unusableAudio: "Couldn't extract the sound from this video. Choose another clip."
            }
        }
    }

    private let file: TemporaryFile
    var sourceURL: URL { file.url }

    init(copying source: URL) throws {
        let file = TemporaryFile(fileExtension: source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        try FileManager.default.copyItem(at: source, to: file.url)
        self.file = file
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try VideoImport(copying: received.file)
        }
    }

    @concurrent func prepare() async throws -> Preview {
        defer { withExtendedLifetime(file) {} }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else { throw ImportError.unplayable }
        let limit = CMTime(value: Int64(Self.maximumDurationSeconds), timescale: 1)
        guard duration <= limit else { throw ImportError.tooLong }
        guard try await asset.load(.isPlayable) else { throw ImportError.unplayable }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let cover = try await generator.image(at: .zero).image

        let dateItem = try? await asset.load(.creationDate)
        let date = try? await dateItem?.load(.dateValue)
        try Task.checkCancellation()

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return Preview(image: cover, date: date, audio: nil) }

        let audio = TemporaryFile(fileExtension: "m4a")
        do {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw ImportError.unusableAudio
            }
            try await exporter.export(to: audio.url, as: .m4a)
            guard try AVAudioFile(forReading: audio.url).length > 0 else { throw ImportError.unusableAudio }
        } catch {
            try Task.checkCancellation()
            throw ImportError.unusableAudio
        }
        try Task.checkCancellation()
        return Preview(image: cover, date: date, audio: audio)
    }
}
