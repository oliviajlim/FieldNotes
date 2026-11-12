# The Field Notes oscilloscope

Press **Record** or **Re-record** on a note to visualize the microphone. Press
**Play** to visualize a saved recording. The 2D display draws a green waveform
on a dark grid and shows a center line during silence, idle, and pause. Display
gain makes quiet waveforms taller while keeping audio volume the same.

Tap **3D** to see a waterfall of up to 12 recent audio slices. The newest trace is
closest to you. Older traces shrink and fade toward the back of the grid.

## Sound to pixels

An oscilloscope plots **amplitude over time**. It uses the signed PCM samples
directly; it doesn't need an FFT.

```text
Microphone → input-node tap → audio file
                           → OscilloscopeSamples

Saved file → player → mixer → speaker
                           → mixer tap → OscilloscopeSamples

OscilloscopeSamples → TimelineView → Canvas → green trace
```

Each sample becomes a point:

```swift
x = sampleIndex / (sampleCount - 1) * width
y = height / 2 - clamp(sample * displayGain, -1, 1) * height * 0.45
```

- **X:** earlier samples at the left, later samples at the right.
- **Y:** zero in the center, positive above, negative below.
- **Gain:** multiplies amplitude for the display. At high gain, peaks flatten
  against the display limit even if the audio itself isn't clipping.

Using absolute values or RMS would lose the sample's sign and produce a level
meter instead of this waveform.

## The three pieces

- `AudioRecorderManager.swift` shares the existing microphone tap with the file
  writer, and installs a mixer tap during playback. Each bus has at most one tap.
  Playback cleanup removes the tap even if the engine fails to start.
- `OscilloscopeSamples.swift` keeps up to 12 slices of 1,024 samples from channel
  1 (left for stereo). It copies them before the engine can reuse its PCM buffer.
  A mutex protects the handoff. The callback tries the lock and skips a visual
  update on contention; the screen makes its own copy rather than retaining the
  audio-side storage. There is no queue of pending visual frames.
- `OscilloscopeView.swift` reads a snapshot and draws connected points with
  `Canvas`, requesting up to 30 screen updates per second (10 with Reduce Motion).
  It pauses updates when inactive or outside the active scene. Other notes show
  an idle line, rather than another note's audio.

The requested audio buffer size is 1,024 frames, but the engine may deliver a
different size. The display uses the actual frame count and sample rate: 1,024
samples at 48 kHz span about **21.3 ms**. This is a short live slice, rather than a
waveform of the entire recording. Display refreshes and audio callbacks have
independent timing.

This first version is free running: it doesn't align each slice to a trigger,
so a steady tone can drift sideways. Zero-crossing triggering, an adjustable
time window, stereo traces, and phosphor trails are possible next steps.

## Check on an iPhone

1. Record a note. Speak or clap; verify the trace responds and gain changes its
   height. Stop, then play the note and check that the trace returns.
2. Pause, resume, and let playback finish. Repeat and switch notes; idle cards
   should stay flat and starting again should not install a duplicate tap.
3. Try quiet input, headphones, a portrait photo, and larger text. Each card can
   scroll vertically to reach the visualizer and controls.

Reference: Apple's [audio node taps](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)),
[PCM channel data](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/floatchanneldata),
and [Canvas](https://developer.apple.com/documentation/swiftui/canvas).
