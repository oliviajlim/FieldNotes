import AVFAudio
import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct VideoImport: Transferable {
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

    enum ImportError: Error {
        case unusableAudio
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
        let asset = AVURLAsset(url: file.url)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let cover = try await generator.image(at: .zero).image

        let dateItem = try? await asset.load(.creationDate)
        let date = try? await dateItem?.load(.dateValue)
        try Task.checkCancellation()

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return Preview(image: cover, date: date, audio: nil) }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.unusableAudio
        }
        let audio = TemporaryFile(fileExtension: "m4a")
        try await exporter.export(to: audio.url, as: .m4a)
        try Task.checkCancellation()

        guard try AVAudioFile(forReading: audio.url).length > 0 else { throw ImportError.unusableAudio }
        return Preview(image: cover, date: date, audio: audio)
    }
}
