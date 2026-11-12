import Photos
import UIKit

enum CameraPhotoLibrary {
    enum Destination {
        case fieldNotesAlbum
        case library
        case accessDenied
    }

    private nonisolated static let albumTitle = "Field Notes"
    private static var lastSave: Task<Destination, Error>?

    static func save(_ capture: CameraCapturePicker.Capture) async throws -> Destination {
        // Serialize album lookup and creation even if the note sheet is reopened during a save.
        let previousSave = lastSave
        let save = Task {
            _ = await previousSave?.result
            return try await saveCapture(capture)
        }
        lastSave = save
        return try await save.value
    }

    private static func saveCapture(_ capture: CameraCapturePicker.Capture) async throws -> Destination {
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else { return .accessDenied }

        let canUseAlbum = access == .authorized
        // Keep the temporary video alive until Photos finishes importing it.
        defer { withExtendedLifetime(capture) {} }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let asset: PHAssetChangeRequest
            switch capture {
            case .photo(let image, let date):
                asset = PHAssetChangeRequest.creationRequestForAsset(from: image)
                if let date { asset.creationDate = date }
            case .video(let video):
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: video.sourceURL, options: nil)
                asset = request
            }

            if canUseAlbum, let placeholder = asset.placeholderForCreatedAsset {
                albumChangeRequest().addAssets([placeholder] as NSArray)
            }
        }

        return canUseAlbum ? .fieldNotesAlbum : .library
    }

    private nonisolated static func albumChangeRequest() -> PHAssetCollectionChangeRequest {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject,
           let request = PHAssetCollectionChangeRequest(for: album) {
            return request
        }
        return PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
    }
}
