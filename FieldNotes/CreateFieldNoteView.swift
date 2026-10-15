//
//  CreateFieldNoteView.swift
//  FieldNotes
//

import CoreData
import PhotosUI
import SwiftUI

/// Sheet for creating a note. The entity is only inserted on Save, so Cancel leaves Core Data untouched.
struct CreateFieldNoteView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var caption = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))
                        } else {
                            Label("Choose Photo", systemImage: "photo.on.rectangle")
                        }
                    }
                }

                Section {
                    TextField("Caption", text: $caption, axis: .vertical)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Field Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(imageData == nil)
                }
            }
            .task(id: selectedPhoto) {
                await loadSelectedPhoto()
            }
        }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }

        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Couldn't load that photo."
                return
            }
            imageData = data
            previewImage = image
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load that photo."
            print("photo load error: \(error)")
        }
    }

    private func save() {
        guard let imageData else { return }

        let note = FieldNoteEntity(context: context)   // awakeFromInsert sets id and createdAt
        note.caption = caption

        var savedFileName: String?
        do {
            let fileName = try ImageStore.save(imageData, id: note.id ?? UUID())
            savedFileName = fileName
            note.imagePath = fileName

            // Not saveIfNeeded: that rolls back silently, and here the user needs to know it failed.
            try context.save()
            dismiss()
        } catch {
            // Undo both halves so Core Data and disk stay in sync.
            context.delete(note)
            if let savedFileName {
                ImageStore.delete(fileName: savedFileName)
            }
            errorMessage = "Couldn't save the note."
            print("save error: \(error)")
        }
    }
}

#Preview {
    CreateFieldNoteView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
