//
//  FieldNote.swift
//  FieldNotes
//
//  Created by Olivia Lim on 9/29/26.
//

import AVKit
import Foundation
import SwiftUI

struct FieldNote: Identifiable {
    let id: UUID = UUID()
    let createdAt: Date
    let imagePath: String
    var audioFileName: String?
    var text: String

    init(createdAt: Date, imagePath: String, audioFileName: String?, text: String) {
        self.createdAt = createdAt
        self.imagePath = imagePath
        self.audioFileName = audioFileName
        self.text = text
    }
}

