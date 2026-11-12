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

#Preview {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)

}
