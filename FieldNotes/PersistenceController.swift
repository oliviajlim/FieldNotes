//
//  PersistenceController.swift
//  FieldNotes
//
//  Created by Olivia Lim on 10/9/26.
//

import CoreData

final class PersistenceController {
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let container = NSPersistentContainer(name: "FieldNoteData")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(filePath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error {
                fatalError(error.localizedDescription)
            }

            print(description.url ?? "no url")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true

        self.container = container
    }
}

extension PersistenceController {
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        for (image, caption) in [("sample-image", "Sun and dance"), ("sample-image-2", "Sleep")] {
            let note = FieldNoteEntity(context: context)
            note.imagePath = image
            note.caption = caption
        }

        try? context.save()

        return controller
    }()
}
