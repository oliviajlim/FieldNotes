//
//  ImageStore.swift
//  FieldNotes
//

import UIKit

/// Stores note photos in Application Support/Images. Core Data keeps only the filename,
/// the same way recordings work.
enum ImageStore {
    enum ImageStoreError: Error {
        case unreadableImage
    }

    nonisolated static func folderURL() throws -> URL {
        let folderURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Images")

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// Re-encodes as JPEG so every stored photo has one predictable format. Returns the filename.
    static func save(_ image: UIImage, id: UUID) throws -> String {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw ImageStoreError.unreadableImage
        }

        let fileName = "\(id.uuidString).jpg"
        try jpeg.write(to: folderURL().appending(path: fileName), options: .atomic)
        return fileName
    }

    static func delete(fileName: String) {
        guard let url = try? folderURL().appending(path: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Reads and decodes off the main actor so large photos don't stall scrolling.
    @concurrent nonisolated static func loadImage(fileName: String) async -> UIImage? {
        guard let url = try? folderURL().appending(path: fileName),
              let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
            return nil
        }
        return await image.byPreparingForDisplay()
    }

}
