import AVFAudio
import CoreData
import SwiftUI

struct HomeView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var audioManager = AudioRecorderManager()
    @State private var isCreatingNote = false
    @FetchRequest(sortDescriptors: [SortDescriptor(\.createdAt, order: .reverse)]) private var notes: FetchedResults<FieldNoteEntity>

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 0) {
                    ForEach(notes) { note in
                        FieldCard(note: note, audioManager: audioManager)
                            .onScrollVisibilityChange { isVisible in
                                if !isVisible, let id = note.id { audioManager.stopVideoPlayback(for: id) }
                            }
                    }

                }
            }
            .background(FieldNoteTheme.paper)
            .scrollTargetBehavior(.paging)
            .navigationTitle("Field Notes")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Field Notes")
                        .font(AppFont.headline)
                        .foregroundStyle(FieldNoteTheme.ink)
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        FieldNoteCalendarView(audioManager: audioManager)
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Field Note", systemImage: "plus") {
                        audioManager.stopVideoPlayback()
                        isCreatingNote = true
                    }
                }
            }
            .sheet(isPresented: $isCreatingNote) {
                CreateFieldNoteView(audioManager: audioManager)
                    .environment(\.managedObjectContext, context)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    audioManager.stopVideoPlayback()
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
    @State private var isRequestingMicrophone = false
    @State private var audioError: String?
    @State private var audioStartPosition: TimeInterval = 0

    /// Checks both sides for nil so an idle manager never matches a note without an ID.
    private var isRecordingThisNote: Bool {
        guard let activeID = audioManager.activeRecordingNoteID else { return false }
        return activeID == note.id
    }

    private var isPlayingThisNote: Bool {
        guard let activeID = audioManager.activePlaybackNoteID else { return false }
        return activeID == note.id && !audioManager.isPaused
    }

    private var isLoadingThisNote: Bool {
        guard let loadingID = audioManager.loadingPlaybackNoteID else { return false }
        return loadingID == note.id
    }

    var body: some View {
        ScrollView(.vertical) {
            cardContent
        }
        .background(FieldNoteTheme.paper)
        .containerRelativeFrame(.horizontal)
        .onChange(of: note.audioFileName) { _, _ in
            audioStartPosition = 0
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imagePath = note.imagePath, note.videoFileName != nil, let id = note.id {
                NoteVideoView(imagePath: imagePath, noteID: id, audioManager: audioManager) {
                    audioError = "Couldn't play this video."
                }
            } else if let imagePath = note.imagePath {
                NoteImageView(imagePath: imagePath)
                    .containerRelativeFrame(.horizontal)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { audioActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { audioActions }
            }
            .buttonStyle(.bordered)
            .disabled(isRequestingMicrophone || audioManager.isStartingRecording || audioManager.loadingPlaybackNoteID != nil
                      || (audioManager.isRecording && !isRecordingThisNote))
            .padding(.horizontal, 20)

            if let fileName = note.videoFileName ?? note.audioFileName, let id = note.id, !isRecordingThisNote {
                AudioScrubber(fileName: fileName, isVideo: note.videoFileName != nil,
                              noteID: id, audioManager: audioManager, startPosition: $audioStartPosition)
                    .id(fileName)
                    .disabled(audioManager.isRecording || audioManager.isStartingRecording || isRequestingMicrophone || isLoadingThisNote)
                    .padding(.horizontal, 20)
            }

            if isRecordingThisNote {
                Label("Recording…", systemImage: "record.circle")
                    .foregroundStyle(FieldNoteTheme.clay)
                    .padding(.horizontal, 20)
            }

            if let audioError {
                Text(audioError)
                    .foregroundStyle(FieldNoteTheme.clay)
                    .padding(.horizontal, 20)
            }

            AudioVisualizerView(
                samples: audioManager.oscilloscopeSamples,
                isActive: isRecordingThisNote || isPlayingThisNote,
                sourceLabel: visualizerSourceLabel
            )
            .padding(.horizontal, 20)

            Group {
                if let date = note.createdAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .foregroundStyle(FieldNoteTheme.ink)
                } else {
                    Text("Date unavailable")
                        .foregroundStyle(FieldNoteTheme.mutedInk)
                }
            }
            .padding(.horizontal, 20)

            TextField("Caption", text: $note.caption)
                .foregroundStyle(FieldNoteTheme.ink)
                .onSubmit {
                    context.saveIfNeeded()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var audioActions: some View {
        if isRecordingThisNote {
            Button("Stop & Save", systemImage: "stop.fill", action: saveRecording)
            Button("Discard Take", systemImage: "xmark") {
                audioManager.discardRecording()
            }
        } else if note.audioFileName != nil || note.videoFileName != nil {
            Button {
                guard let id = note.id else { return }
                audioError = nil
                if isPlayingThisNote {
                    audioManager.pausePlayback()
                } else {
                    Task { await startPlayback(id: id) }
                }
            } label: {
                if isLoadingThisNote {
                    Label {
                        Text("Loading…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Label(isPlayingThisNote ? "Pause" : "Play", systemImage: isPlayingThisNote ? "pause.fill" : "play.fill")
                }
            }
            Button(note.audioFileName == nil ? "Record" : "Re-record", systemImage: "mic") {
                Task { await startRecording() }
            }
        } else {
            Button("Record", systemImage: "mic") {
                Task { await startRecording() }
            }
        }
    }

    private func startPlayback(id: UUID) async {
        do {
            try await audioManager.play(fileName: note.audioFileName, videoFileName: note.videoFileName,
                                        noteID: id, from: audioStartPosition)
            if audioManager.activePlaybackNoteID == id { audioStartPosition = 0 }
        } catch is CancellationError {
            return
        } catch {
            audioError = note.videoFileName == nil ? "Couldn't play this recording." : "Couldn't play this video."
            print("Playback start failed: \(error)")
        }
    }

    private func startRecording() async {
        guard let id = note.id, !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        audioError = nil
        defer { isRequestingMicrophone = false }

        guard await audioManager.requestMicrophonePermissions() else {
            audioError = "Allow microphone access in Settings to record audio."
            return
        }

        do {
            try await audioManager.startRecording(id: id)
        } catch is CancellationError {
            return
        } catch {
            audioError = "Couldn't start recording. Check your microphone and try again."
            print("Recording start failed: \(error)")
        }
    }

    private func saveRecording() {
        let fileName: String
        do {
            guard let finishedTake = try audioManager.stopRecording() else { return }
            fileName = finishedTake
        } catch {
            audioError = "Couldn't finish that take. Try recording again."
            return
        }

        let previousFile = note.audioFileName
        note.audioFileName = fileName
        do {
            try context.save()
            if let previousFile {
                AudioRecorderManager.deleteRecording(fileName: previousFile)
            }
        } catch {
            note.audioFileName = previousFile
            AudioRecorderManager.deleteRecording(fileName: fileName)
            audioError = "Couldn't save that take. Try recording again."
            print("Recording save failed: \(error)")
        }
    }

    private var visualizerSourceLabel: String {
        if isRecordingThisNote { return "Microphone" }
        if isPlayingThisNote { return "Playback" }
        if audioManager.activePlaybackNoteID == note.id, audioManager.isPaused { return "Paused" }
        return "Idle"
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

