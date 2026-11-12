import AVFoundation

enum NoteVideoPlayback {
    private enum PlaybackError: Error { case invalidVideo, invalidAudio }

    static func load(videoURL: URL, audioURL: URL?) async throws -> (AVPlayerItem, CMTime, VideoWaveform?) {
        let movie = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await movie.load(.duration)
        guard duration.isNumeric, duration > .zero else { throw PlaybackError.invalidVideo }

        let playbackAsset: AVAsset
        if let audioURL {
            // Use the note's saved recording as the soundtrack. A single player keeps it
            // synchronized with the picture, including after a pause or seek.
            let audio = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let composition = AVMutableComposition()
            let clipRange = CMTimeRange(start: .zero, duration: duration)
            guard let sourceVideo = try await movie.loadTracks(withMediaType: .video).first,
                  let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw PlaybackError.invalidVideo }
            let picture = clipRange.intersection(try await sourceVideo.load(.timeRange))
            guard !picture.isEmpty else { throw PlaybackError.invalidVideo }
            try video.insertTimeRange(picture, of: sourceVideo, at: picture.start)
            video.preferredTransform = try await sourceVideo.load(.preferredTransform)

            guard let sourceAudio = try await audio.loadTracks(withMediaType: .audio).first,
                  let soundtrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw PlaybackError.invalidAudio }
            let sound = clipRange.intersection(try await sourceAudio.load(.timeRange))
            guard !sound.isEmpty else { throw PlaybackError.invalidAudio }
            try soundtrack.insertTimeRange(sound, of: sourceAudio, at: sound.start)
            if composition.duration < duration {
                composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration))
            }
            playbackAsset = composition
        } else {
            // Silent clips and notes saved before soundtrack extraction was enabled.
            playbackAsset = movie
        }

        // Decode the same timeline we play. A failed visualization must not block playback.
        let waveform: VideoWaveform?
        do {
            waveform = try await VideoWaveform.decode(asset: playbackAsset, duration: duration)
        } catch {
            try Task.checkCancellation()
            print("Couldn't prepare video waveform: \(error)")
            waveform = nil
        }
        return (AVPlayerItem(asset: playbackAsset), duration, waveform)
    }
}
