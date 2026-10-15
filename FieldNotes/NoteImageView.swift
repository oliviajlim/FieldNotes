//
//  NoteImageView.swift
//  FieldNotes
//

import SwiftUI

/// Shows a note's photo from disk, falling back to an asset-catalog image
/// (sample and preview notes use asset names like "sample-image").
struct NoteImageView: View {
    let imagePath: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: imagePath) {
            image = await ImageStore.loadImage(fileName: imagePath) ?? UIImage(named: imagePath)
        }
    }
}
