//
//  CreateFieldNoteView.swift
//  FieldNotes
//

import AVFoundation
import CoreData
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for creating a note. The entity is only inserted on Save, so Cancel leaves Core Data untouched.
struct CreateFieldNoteView: View {
    private struct Media {
        let image: UIImage
        let date: Date?
        var video: VideoImport?
        var audio: VideoImport.TemporaryFile?
    }

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let audioManager: AudioRecorderManager

    @State private var librarySelection: PhotosPickerItem?
    @State private var media: Media?
    @State private var cameraRequest: CameraCapturePicker.Mode?
    @State private var presentedCamera: CameraCapturePicker.Mode?
    @State private var isCameraCoverOpen = false
    @State private var capturedVideo: VideoImport?
    @State private var caption = ""
    @State private var errorMessage: String?
    @State private var photosSaveID: UUID?
    @State private var photosSaveMessage: String?
    @State private var isSaving = false

    private var isPreparingMedia: Bool { librarySelection != nil || capturedVideo != nil }
    private var isBusy: Bool { isSaving || isPreparingMedia || cameraRequest != nil || isCameraCoverOpen }
    private var canPrepareCapturedVideo: Bool { capturedVideo != nil && !isCameraCoverOpen }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let media {
                        Image(uiImage: media.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))

                        if let date = media.date {
                            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                                .foregroundStyle(FieldNoteTheme.mutedInk)
                        } else {
                            Text("Date unavailable")
                                .foregroundStyle(FieldNoteTheme.mutedInk)
                        }

                        if media.video != nil {
                            Label(
                                media.audio == nil ? "Video has no audio" : "Video audio included",
                                systemImage: media.audio == nil ? "speaker.slash" : "waveform"
                            )
                                .foregroundStyle(FieldNoteTheme.mutedInk)
                        }
                    }

                    Button("Take Photo", systemImage: "camera") {
                        cameraRequest = .photo
                    }
                    .disabled(isBusy)

                    Button("Record Video", systemImage: "video") {
                        cameraRequest = .video
                    }
                    .disabled(isBusy)

                    PhotosPicker(
                        selection: $librarySelection,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    ) {
                        Label("Choose Photo or Video", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isBusy)

                    if isPreparingMedia {
                        ProgressView("Preparing media…")
                            .foregroundStyle(FieldNoteTheme.mutedInk)
                    }

                    if let photosSaveMessage {
                        Text(photosSaveMessage)
                            .foregroundStyle(FieldNoteTheme.mutedInk)
                    }
                } footer: {
                    Text("Videos can be up to \(VideoImport.maximumDurationSeconds) seconds long.")
                }
                .listRowBackground(FieldNoteTheme.surface)

                Section {
                    TextField("Caption", text: $caption, axis: .vertical)
                        .foregroundStyle(FieldNoteTheme.ink)
                }
                .listRowBackground(FieldNoteTheme.surface)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(FieldNoteTheme.clay)
                    }
                    .listRowBackground(FieldNoteTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(FieldNoteTheme.paper)
            .navigationTitle("New Field Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New Field Note")
                        .font(AppFont.headline)
                        .foregroundStyle(FieldNoteTheme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(media == nil || isBusy)
                }
            }
            .task(id: librarySelection) {
                await loadSelectedMedia()
            }
            .task(id: cameraRequest) {
                if let mode = cameraRequest { await openCamera(mode) }
            }
            .task(id: canPrepareCapturedVideo) {
                if canPrepareCapturedVideo { await prepareCapturedVideo() }
            }
            .fullScreenCover(item: $presentedCamera, onDismiss: { isCameraCoverOpen = false }) { mode in
                CameraCapturePicker(
                    mode: mode,
                    onCapture: receiveCapture,
                    onCancel: { presentedCamera = nil }
                )
                .ignoresSafeArea()
            }
        }
        .font(AppFont.body)
        .interactiveDismissDisabled(isSaving)
    }

    private func loadSelectedMedia() async {
        guard let selection = librarySelection else { return }
        defer {
            if librarySelection == selection { librarySelection = nil }
        }

        let mediaType = selection.supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        let isVideo = mediaType?.conforms(to: .movie) == true
        let failureMessage = isVideo ? "Couldn't import that video." : "Couldn't load that photo."
        errorMessage = nil

        do {
            let selectedMedia: Media
            if isVideo {
                guard let video = try await selection.loadTransferable(type: VideoImport.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                selectedMedia = try await prepareVideo(video)
            } else {
                guard let data = try await selection.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                selectedMedia = Media(image: image, date: PhotoCaptureDate.read(from: data))
            }
            guard !Task.isCancelled, librarySelection == selection else { return }
            photosSaveID = nil
            photosSaveMessage = nil
            media = selectedMedia
        } catch {
            guard !Task.isCancelled, librarySelection == selection else { return }
            errorMessage = (error as? VideoImport.ImportError)?.errorDescription ?? failureMessage
            print("Media import failed: \(error)")
        }
    }

    private func openCamera(_ mode: CameraCapturePicker.Mode) async {
        defer {
            if cameraRequest == mode { cameraRequest = nil }
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "Camera is unavailable on this device."
            return
        }
        guard UIImagePickerController.availableMediaTypes(for: .camera)?.contains(mode.mediaType.identifier) == true else {
            errorMessage = "This camera doesn't support that capture mode."
            return
        }
        guard !audioManager.isRecording, !audioManager.isStartingRecording else {
            errorMessage = "Stop the current audio recording before opening the camera."
            return
        }

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard !Task.isCancelled else { return }
        guard granted else {
            errorMessage = "Allow camera access in Settings to take photos or videos."
            return
        }

        if mode == .video {
            let microphoneGranted = await audioManager.requestMicrophonePermissions()
            guard !Task.isCancelled else { return }
            guard microphoneGranted else {
                errorMessage = "Allow microphone access in Settings to record video with sound."
                return
            }
        }

        if mode == .video {
            await audioManager.prepareForVideoCapture()
            guard !Task.isCancelled else { return }
        }

        guard !audioManager.isRecording, !audioManager.isStartingRecording else {
            errorMessage = "Stop the current audio recording before opening the camera."
            return
        }
        errorMessage = nil
        isCameraCoverOpen = true
        presentedCamera = mode
    }

    private func receiveCapture(_ result: Result<CameraCapturePicker.Capture, Error>) {
        presentedCamera = nil
        switch result {
        case .success(let capture):
            switch capture {
            case .photo(let image, let date):
                media = Media(image: image, date: date)
            case .video(let video):
                capturedVideo = video
            }
            saveCaptureToPhotos(capture)
        case .failure(let error):
            errorMessage = "Couldn't load the camera capture."
            print("Camera capture failed: \(error)")
        }
    }

    private func saveCaptureToPhotos(_ capture: CameraCapturePicker.Capture) {
        let id = UUID()
        photosSaveID = id
        photosSaveMessage = "Saving to Photos…"

        // Confirming the capture saves it to Photos even if the note draft is later dismissed.
        Task {
            let message: String
            do {
                switch try await CameraPhotoLibrary.save(capture) {
                case .fieldNotesAlbum:
                    message = "Saved to the Field Notes album in Photos."
                case .library:
                    message = "Saved to Photos. Allow full Photos access in Settings to add future captures to Field Notes."
                case .accessDenied:
                    message = "Allow Photos access in Settings to save captures to the Field Notes album."
                }
            } catch {
                message = "Couldn't save this capture to Photos."
                print("Photos save failed: \(error)")
            }
            if photosSaveID == id { photosSaveMessage = message }
        }
    }

    private func prepareCapturedVideo() async {
        guard !Task.isCancelled, let video = capturedVideo else { return }
        defer { capturedVideo = nil }

        do {
            let prepared = try await prepareVideo(video)
            try Task.checkCancellation()
            media = prepared
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? VideoImport.ImportError)?.errorDescription ?? "Couldn't prepare the recorded video."
            print("Captured video import failed: \(error)")
        }
    }

    private func prepareVideo(_ video: VideoImport) async throws -> Media {
        let preview = try await video.prepare()
        return Media(image: UIImage(cgImage: preview.image), date: preview.date, video: video, audio: preview.audio)
    }

    private func save() async {
        guard let media, !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        let caption = caption
        let noteID = UUID()
        var videoFileName: String?
        var audioFileName: String?
        var imagePath: String?
        var unsavedNote: FieldNoteEntity?
        do {
            if let video = media.video {
                videoFileName = try await VideoStore.save(video, id: noteID)
            }
            if let audio = media.audio {
                audioFileName = try AudioRecorderManager.importRecording(from: audio.url, noteID: noteID)
            }
            imagePath = try ImageStore.save(media.image, id: noteID)

            let note = FieldNoteEntity(context: context)
            unsavedNote = note
            note.id = noteID
            note.caption = caption
            note.createdAt = media.date
            note.imagePath = imagePath
            note.videoFileName = videoFileName
            note.audioFileName = audioFileName

            // Not saveIfNeeded: that rolls back silently, and here the user needs to know it failed.
            try context.save()
            dismiss()
        } catch {
            if let imagePath { ImageStore.delete(fileName: imagePath) }
            if let videoFileName { VideoStore.delete(fileName: videoFileName) }
            if let audioFileName { AudioRecorderManager.deleteRecording(fileName: audioFileName) }
            if let unsavedNote { context.delete(unsavedNote) }
            errorMessage = "Couldn't save the note."
            print("save error: \(error)")
        }
    }
}

#Preview {
    CreateFieldNoteView(audioManager: AudioRecorderManager())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
