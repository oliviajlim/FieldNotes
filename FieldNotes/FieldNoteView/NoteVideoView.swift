import AVFoundation
import Combine
import SwiftUI
import UIKit

struct NoteVideoView: View {
    let imagePath: String
    let noteID: UUID
    let audioManager: AudioRecorderManager
    let onFailure: () -> Void

    var body: some View {
        NoteImageView(imagePath: imagePath)
            .containerRelativeFrame(.horizontal)
            .overlay {
                if let player = audioManager.videoPlayer(for: noteID), let item = player.currentItem {
                    VideoSurface(player: player)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                            if status == .failed { handlePlaybackFailure(for: player) }
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item
                        ).receive(on: DispatchQueue.main)) { _ in
                            handlePlaybackFailure(for: player)
                        }
                }
            }
            .onDisappear { audioManager.stopVideoPlayback(for: noteID) }
    }

    private func handlePlaybackFailure(for player: AVPlayer) {
        guard audioManager.videoPlayer(for: noteID) === player else { return }
        audioManager.stopVideoPlayback(for: noteID)
        onFailure()
    }
}

/// The card's Play button and scrubber control this surface along with the soundtrack.
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView { PlayerView() }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
