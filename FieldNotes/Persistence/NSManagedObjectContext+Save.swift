//
//  NSManagedObjectContext+Save.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/10/26.
//

import CoreData

extension NSManagedObjectContext {
    func saveIfNeeded() {
        guard hasChanges else { return }   // nothing edited, so skip the disk write

        do {
            try save()
        } catch {
            rollback()
            print("didn't save \(error)")
        }
    }
}
