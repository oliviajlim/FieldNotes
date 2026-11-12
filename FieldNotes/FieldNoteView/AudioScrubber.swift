import SwiftUI

struct AudioScrubber: View {
    let fileName: String
    let isVideo: Bool
    let noteID: UUID
    let audioManager: AudioRecorderManager
    @Binding var startPosition: TimeInterval

    @Environment(\.scenePhase) private var scenePhase
    @State private var duration: TimeInterval?
    @State private var couldNotLoadAudio = false
    @State private var draggedPosition: TimeInterval?

    private var isPlaying: Bool {
        audioManager.activePlaybackNoteID == noteID && !audioManager.isPaused
    }

    var body: some View {
        Group {
            if let duration {
                TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying || scenePhase != .active)) { _ in
                    let current = audioManager.playbackPosition(for: noteID) ?? startPosition
                    let position = min(duration, max(0, draggedPosition ?? current))

                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(get: { position }, set: updateSlider),
                            in: 0...duration,
                            onEditingChanged: { editing in
                                if editing {
                                    draggedPosition = position
                                } else if let draggedPosition {
                                    seek(to: draggedPosition)
                                    self.draggedPosition = nil
                                }
                            }
                        )
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(timeText(position)) of \(timeText(duration))")

                        HStack {
                            Text(timeText(position))
                            Spacer()
                            Text(timeText(duration))
                        }
                        .font(AppFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(FieldNoteTheme.mutedInk)
                        .accessibilityHidden(true)
                    }
                }
            } else if couldNotLoadAudio {
                Text(isVideo ? "Video unavailable" : "Audio unavailable")
                    .font(AppFont.caption)
                    .foregroundStyle(FieldNoteTheme.mutedInk)
            }
        }
        .task(id: fileName) {
            let loadedDuration = if isVideo {
                await VideoStore.duration(fileName: fileName)
            } else {
                await AudioRecorderManager.duration(fileName: fileName)
            }
            guard !Task.isCancelled else { return }
            duration = loadedDuration
            couldNotLoadAudio = loadedDuration == nil
        }
    }

    private func updateSlider(_ position: TimeInterval) {
        if draggedPosition != nil {
            draggedPosition = position
        } else {
            // VoiceOver and keyboard adjustments can arrive without a drag.
            seek(to: position)
        }
    }

    private func seek(to position: TimeInterval) {
        if audioManager.activePlaybackNoteID == noteID {
            audioManager.seek(to: position, noteID: noteID)
        } else {
            startPosition = position
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let time = Duration.seconds(seconds.rounded(.down))
        return time.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
