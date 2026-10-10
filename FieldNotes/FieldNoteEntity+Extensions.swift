//
//  FieldNoteEntity+Extensions.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/9/26.
//

import CoreData

extension FieldNoteEntity {
    nonisolated var caption: String {
        get { return text ?? "" }
        set { self.text = newValue }
    }

    nonisolated override public func awakeFromInsert() {
        super.awakeFromInsert()

        self.id = UUID()
        self.createdAt = Date()
        self.text = ""
    }
}
