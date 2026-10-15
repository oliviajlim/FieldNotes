import AVFAudio
import CoreData
import SwiftUI

struct HomeView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State var audioManager = AudioRecorderManager()
    @State private var isCreatingNote = false
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
                    isCreatingNote = true
                }, label: {
                    Image(systemName: "plus")
                })
            }
            .sheet(isPresented: $isCreatingNote) {
                CreateFieldNoteView()
                    .environment(\.managedObjectContext, context)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    context.saveIfNeeded()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}


struct FieldCard: View {
    @ObservedObject var note: FieldNoteEntity
    @Environment(\.managedObjectContext) private var context
    let audioManager: AudioRecorderManager

    /// Checks both sides for nil so an idle manager never matches a note without an ID.
    private var isRecordingThisNote: Bool {
        guard let activeID = audioManager.activeRecordingNoteID else { return false }
        return activeID == note.id
    }

    private var isPlayingThisNote: Bool {
        guard let activeID = audioManager.activePlaybackNoteID else { return false }
        return activeID == note.id && !audioManager.isPaused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imagePath = note.imagePath {
                NoteImageView(imagePath: imagePath)
                    .containerRelativeFrame(.horizontal)
            }

            if note.audioFileName == nil {
                Button(isRecordingThisNote ? "Stop" : "Record") {
                    if isRecordingThisNote {
                        // Point the note at the file only after it's finished and closed.
                        if let fileName = audioManager.stopRecording() {
                            note.audioFileName = fileName
                            context.saveIfNeeded()
                        }
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
                // Only one recording at a time: other cards can't start while one is active.
                .disabled(audioManager.isRecording && !isRecordingThisNote)
                .padding(.horizontal, 20)
            } else {
                Button(isPlayingThisNote ? "Pause" : "Play") {
                    guard let id = note.id, let fileName = note.audioFileName else { return }

                    if isPlayingThisNote {
                        audioManager.pausePlayback()
                    } else {
                        audioManager.play(fileName: fileName, noteID: id)
                    }
                }
                .disabled(audioManager.isRecording)
                .padding(.horizontal, 20)
            }

            if isRecordingThisNote {
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

