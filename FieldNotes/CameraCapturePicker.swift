import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraCapturePicker: UIViewControllerRepresentable {
    enum Mode: Identifiable {
        case photo
        case video

        var id: Self { self }
        var mediaType: UTType { self == .video ? .movie : .image }
    }

    nonisolated enum Capture: Sendable {
        case photo(UIImage, Date?)
        case video(VideoImport)
    }

    let mode: Mode
    let onCapture: (Result<Capture, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [mode.mediaType.identifier]
        picker.cameraCaptureMode = mode == .video ? .video : .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(picker: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let picker: CameraCapturePicker

        init(picker: CameraCapturePicker) {
            self.picker = picker
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            do {
                let capture: Capture
                switch self.picker.mode {
                case .photo:
                    guard let image = info[.originalImage] as? UIImage else { throw CocoaError(.fileReadCorruptFile) }
                    let metadata = info[.mediaMetadata] as? [String: Any] ?? [:]
                    capture = .photo(image, PhotoCaptureDate.read(from: metadata))
                case .video:
                    guard let url = info[.mediaURL] as? URL else { throw CocoaError(.fileReadUnknown) }
                    // Copy the camera's temporary movie before the picker is dismissed.
                    capture = .video(try VideoImport(copying: url))
                }
                self.picker.onCapture(.success(capture))
            } catch {
                self.picker.onCapture(.failure(error))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            self.picker.onCancel()
        }
    }
}
