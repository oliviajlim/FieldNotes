import AVFoundation
import Foundation

nonisolated enum VideoStore {
    static func fileURL(for fileName: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "Videos").appending(path: fileName)
    }

    @concurrent static func save(_ video: VideoImport, id: UUID) async throws -> String {
        defer { withExtendedLifetime(video) {} }
        try Task.checkCancellation()
        let fileName = "\(id.uuidString).\(video.sourceURL.pathExtension)"
        let destination = try fileURL(for: fileName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: video.sourceURL, to: destination)
            try Task.checkCancellation()
            return fileName
        } catch {
            delete(fileName: fileName)
            throw error
        }
    }

    static func delete(fileName: String) {
        guard let url = try? fileURL(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @concurrent static func duration(fileName: String) async -> TimeInterval? {
        guard let url = try? fileURL(for: fileName) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero else { return nil }
        return duration.seconds
    }
}
