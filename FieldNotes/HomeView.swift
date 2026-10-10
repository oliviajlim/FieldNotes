import AVFAudio
import CoreData
import SwiftUI

struct HomeView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State var audioManager = AudioRecorderManager()
    @FetchRequest(sortDescriptors: [SortDescriptor(\.createdAt, order: .reverse)]) private var notes: FetchedResults<FieldNoteEntity>

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 0) {
                    ForEach(notes) { note in
                        FieldCard(note: note, audioManager: audioManager)
                    }

                }
            }
            .scrollTargetBehavior(.paging)
            .navigationTitle("Field Notes")
            .toolbar {
                Button(action: {
                    addNote()
                }, label: {
                    Image(systemName: "plus")
                })
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    context.saveIfNeeded()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func addNote()  {
        let fieldNote = FieldNoteEntity(context: context)
        fieldNote.imagePath = "sample-image"

        context.saveIfNeeded()
    }
}


struct FieldCard: View {
    @ObservedObject var note: FieldNoteEntity
    @Environment(\.managedObjectContext) private var context
    let audioManager: AudioRecorderManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imagePath = note.imagePath {
                Image(imagePath)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .containerRelativeFrame(.horizontal)
            }

            if note.audioFileName == nil {
                Button("Record") {
                    guard !audioManager.isRecording else {
                        audioManager.stopRecording()
                        return
                    }

                    guard let id = note.id else {
                        print("missing id")
                        return
                    }

                    Task {
                        if await audioManager.requestMicrophonePermissions() {
                            audioManager.startRecording(id: id)
                        }
                    }
                }
                .padding(.horizontal, 20)
            } else {
                Button("Play") {
                    print("play: \(String(describing: note.audioFileName))")

                }
                .padding(.horizontal, 20)
            }

            if audioManager.activeRecordingNoteID == note.id {
                Text("Recording...")
                    .padding(.horizontal, 20)
            }

            Text(note.createdAt ?? Date(), format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .padding(.horizontal, 20)

            TextField("Caption", text: $note.caption)
                .onSubmit {
                    context.saveIfNeeded()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }
}

#Preview {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)

}

#Preview("Field Card") {
    let note = FieldNoteEntity(context: PersistenceController.preview.container.viewContext)
    note.imagePath = "sample-image"
    note.caption = "new caption"

    return FieldCard(note: note, audioManager: AudioRecorderManager())
}

