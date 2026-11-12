//
//  NoteImageView.swift
//  FieldNotes
//

import SwiftUI

/// Shows a note's photo from disk, falling back to an asset-catalog image
/// (sample and preview notes use asset names like "sample-image").
struct NoteImageView: View {
    let imagePath: String
    let thumbnailPixelSize: Int?

    @State private var image: UIImage?

    init(imagePath: String, thumbnailPixelSize: Int? = nil) {
        self.imagePath = imagePath
        self.thumbnailPixelSize = thumbnailPixelSize
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: thumbnailPixelSize == nil ? .fit : .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: imagePath) {
            image = nil
            let loaded: UIImage?
            if let thumbnailPixelSize {
                loaded = await ImageStore.loadThumbnail(fileName: imagePath, maxPixelSize: thumbnailPixelSize)
            } else {
                loaded = await ImageStore.loadImage(fileName: imagePath)
            }
            guard !Task.isCancelled else { return }
            image = loaded ?? UIImage(named: imagePath)
        }
    }
}
