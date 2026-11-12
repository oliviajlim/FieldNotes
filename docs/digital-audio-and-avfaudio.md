# Digital Audio & AVFAudio Basics

A beginner's reference for recording audio in Field Notes with `AVAudioEngine`.

---

## Part 1: Digital Audio

### Sound is air wiggling

When you talk, your voice pushes air back and forth very fast. A microphone has a thin plate that moves with the air. A gentle sound moves it a little, a loud one moves it a lot.

### Computers store sound as numbers

The phone **measures the plate's position over and over** and writes down a number each time. Each measurement is a **sample**.

| Plate position | Sample value |
|---|---|
| Pushed out | `+0.8` |
| Resting (silence) | `0.0` |
| Pulled in | `-0.5` |

- Samples are decimals between **-1.0 and +1.0**.
- **Near 0 = quiet.** **Near ±1 = loud.**
- A silent recording is mostly numbers close to 0.

### Sample rate: measurements per second

An iPhone mic usually takes **48,000 samples per second**, written **48 kHz**.

> 🎞️ Video is a flipbook of ~30 pictures per second. Digital audio is a flipbook of ~48,000 numbers per second.

One second of mono audio is literally a list of 48,000 numbers.

### Channels: how many microphones

| Name | Channels | Meaning |
|---|---|---|
| Mono | 1 | One list of numbers |
| Stereo | 2 | Two lists (left + right) |

The iPhone's built-in mic usually records mono.

### Frames

A **frame** is one moment in time, with one sample per channel.

- Mono: 1 frame = 1 sample
- Stereo: 1 frame = 2 samples (left + right)

### Converting frames to time ⭐

```text
time (seconds) = frames ÷ sample rate
```

| Frames | Sample rate | Time |
|---|---|---|
| 48,000 | 48,000 | 1 s |
| 4,800 | 48,000 | 0.1 s |
| 2,400 | 48,000 | 0.05 s |
| 4,410 | 44,100 | 0.1 s |

Tip: time is always measured against **one second** (the sample rate), not against some other buffer size.

### PCM vs compressed audio

| | PCM | AAC (`.m4a`) |
|---|---|---|
| What it is | Raw list of sample numbers | Compressed audio, like JPEG for photos |
| Size (mono, ~1 min) | ~11 MB | ~1 MB |
| Can you measure loudness directly? | ✅ Yes | ❌ No, it must be decoded first |
| Where we use it | **In memory**, while recording | **On disk**, when saving |

**Why both?** We need raw numbers *while recording* so we can measure them (for a live waveform), and a small file *when saving*.

---

## Part 2: AVFAudio

### The four pieces

| Piece | Job | Analogy |
|---|---|---|
| `AVAudioSession` | Tells iOS how your app will use audio and claims the hardware | Booking the recording studio |
| `AVAudioEngine` | Moves audio through a chain of **nodes** while running | The plumbing |
| Tap on `inputNode` | Hands your code each chunk of mic audio | A spout on the pipe |
| `AVAudioFile` | Stores the chunks on disk | The bucket |

> The engine never saves anything by itself. **Recording = moving each chunk from the spout into the bucket.**

---

### `AVAudioSession`

Your iPhone has one mic and one speaker, but many apps want them. The session is how your app tells iOS what it needs, so iOS can share the hardware.

#### Step A: `setCategory`, filling out the form

Declares what you *plan* to do. It doesn't ask for anything, so it rarely fails.

| Category | Meaning |
|---|---|
| `.playback` | Only play sound |
| `.record` | Only record |
| `.playAndRecord` | Both, which is what Field Notes uses |

#### Step B: `setActive(true)`, handing in the form

**Actually claims the hardware.** At this moment iOS may pause other apps (music, podcasts).

This **can fail** even when `setCategory` succeeded, for example during a **phone call**: the Phone app has higher priority and already holds the mic.

> 🎙️ The form is filled out perfectly, but the studio is already booked by someone more important.

#### Cleaning up

```swift
try session.setActive(false, options: .notifyOthersOnDeactivation)
```

Without this, iOS thinks you still own the hardware, so **a podcast the user paused won't resume on its own**. `.notifyOthersOnDeactivation` tells other apps "I'm done, you can continue."

---

### `AVAudioEngine`, nodes, and buses

The engine is a graph of **nodes** that audio flows through:

```text
[ inputNode ]  →  [ mainMixerNode ]  →  [ outputNode ]
  microphone          mixing             speaker
```

- **`inputNode`** is the microphone's spot in the graph. The engine already has one; you don't create it.
- **Bus** is a numbered connection socket on a node. The mic node's output is **bus 0**.
- **No audio flows until `engine.start()`.** Installing a tap without starting the engine gives you nothing.

#### Asking the mic for its format

```swift
let format = audioEngine.inputNode.outputFormat(forBus: 0)
```

- `outputFormat` is what comes **out** of the mic node, toward your tap.
- **Ask only after `setActive(true)`.** Before activation, iOS hasn't connected you to the real hardware, so the answer may be wrong.
- **Never hardcode the format.** The built-in mic, AirPods, and the Mac (in the simulator) can all differ.

Example printout:

```text
<AVAudioFormat 0x...:  1 ch,  48000 Hz, Float32>
```

| Part | Meaning |
|---|---|
| `1 ch` | 1 channel (mono) |
| `48000 Hz` | 48,000 samples per second |
| `Float32` | Each sample is a 32-bit decimal number |

---

### The tap and `AVAudioPCMBuffer`

A **tap** is a listener attached to a node's bus. The engine doesn't hand you one number at a time; it collects frames into a **buffer** (`AVAudioPCMBuffer`) and calls your closure with each one.

- `buffer.frameLength` is how many frames are in this chunk.
- Example: 4,800 frames at 48 kHz → **10 buffers per second**, each holding 0.1 s.
- **One tap per bus.** Installing a second tap on a bus that already has one **crashes**. Always `removeTap(onBus:)` when you stop.

#### ⚠️ The tap runs on a different thread

The tap closure runs on a high-priority **audio thread**, not the main thread. This project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so closures written inside a class default to main-actor isolation, and **the app crashes when audio arrives**. Create the tap closure inside a `nonisolated` function. (See the `swift-concurrency` skill for the full explanation.)

---

### `AVAudioFile`: two formats at once

| | Describes | Set with |
|---|---|---|
| **File format** (on disk) | AAC, sample rate, channels | `settings:` dictionary |
| **Processing format** (in memory) | The PCM buffers you'll hand it | `commonFormat:` / `interleaved:` |

`AVAudioFile` converts between them for you. The processing side **must match the tap's buffers**. If the file was told 44,100 Hz but the mic delivers 48,000 Hz, `write(from:)` throws.

**`close()` matters.** AAC writes the end of the file only when closed. An `.m4a` that's never closed is often **unplayable**.

---

## Part 3: The Recording Timeline

```text
TAP RECORD
  1. Session:  setCategory(.playAndRecord), setActive(true)   ← book the studio
  2. Format:   inputNode.outputFormat(forBus: 0)              ← ask the mic
  3. File:     open AVAudioFile for writing                   ← put the bucket down
  4. Tap:      installTap on inputNode                        ← attach the spout
  5. Engine:   start()                                        ← turn on the water
  6. State:    only now mark the note as "recording"

  ...on the audio thread, whenever the engine delivers a buffer:
       tap receives a buffer → oscilloscopeSamples.capture(buffer)
                             → file.write(from: buffer)

TAP STOP
  7. removeTap                                                ← detach the spout
  8. engine.stop()                                            ← turn off the water
  9. file.close()                                             ← seal the bucket
 10. Session:  setActive(false, .notifyOthersOnDeactivation)  ← give the studio back
```

### Rules behind the order

1. **No buffers may be flowing when you close the file.** Otherwise a buffer can arrive (on the audio thread) after the file is sealed.
2. **The tap must always be removed**, or the next `installTap` crashes.
3. **Claim "recording" only after everything succeeds.** Don't set state first and undo it on failure.

---

## Part 4: Simulator vs. iPhone

The simulator runs your app as a Mac program, so it uses **your Mac's microphone**.

| Use | Where |
|---|---|
| Check that buffers flow and the file is written | Simulator is fine |
| Real iPhone format, permission behavior, interruptions (calls, headphones, Siri) | iPhone |
| Final acceptance testing | iPhone |

Simulator gotchas:
- The format will be the Mac's (e.g. `2 ch, 44100 Hz`). This isn't a bug, and it's why we never hardcode.
- With no Mac input device, the format can be `0 Hz, 0 ch`, and installing a tap with that crashes.
- macOS has its own mic permission for Xcode/Simulator, separate from the iOS prompt.

---

## Glossary

| Term | Meaning |
|---|---|
| **Sample** | One measurement of the mic plate, -1.0 to +1.0 |
| **Sample rate** | Samples per second (Hz), e.g. 48,000 |
| **Channel** | One independent stream (mono = 1, stereo = 2) |
| **Frame** | One moment in time, one sample per channel |
| **Buffer** | A chunk of frames handed to you at once (`AVAudioPCMBuffer`) |
| **PCM** | Raw, uncompressed sample numbers |
| **AAC / `.m4a`** | Compressed audio format for saving |
| **Session** | Your app's agreement with iOS about audio hardware |
| **Category** | What kind of audio you'll do (`.playAndRecord`) |
| **Node** | A stage in the engine's graph (`inputNode`, `mainMixerNode`, …) |
| **Bus** | A numbered connection socket on a node |
| **Tap** | A listener that receives buffers flowing through a bus |
| **Format** | Description of audio data: sample rate, channels, number type |

---

## Self-Quiz

1. A buffer has 2,400 frames at 48 kHz. How long is it?
2. What are most samples close to in a silent recording?
3. Why keep PCM in memory while recording but save AAC?
4. What's the difference between `setCategory` and `setActive(true)`?
5. Why can `setActive(true)` fail during a phone call?
6. Why ask for the input format only after activating?
7. What happens if you never call `setActive(false, ...)`?
8. What crashes if you forget `removeTap`, and when?
9. Does the tap get called if you never call `engine.start()`?
10. The simulator prints `2 ch, 44100 Hz`. Is your code broken?

<details>
<summary>Answers</summary>

1. 0.05 s (48,000 ÷ 2,400 = 20 buffers per second).
2. 0.
3. PCM can be measured directly (for a live waveform); AAC keeps the saved file small.
4. `setCategory` declares what you'll do; `setActive(true)` actually claims the hardware.
5. The Phone app holds the mic with higher priority, so iOS refuses your claim.
6. Before activation you aren't connected to the real hardware, so the format may be wrong.
7. Other apps' audio (like a paused podcast) won't resume on its own.
8. The *next* `installTap` crashes, because a bus allows only one tap.
9. No. The engine is what pulls audio from the mic.
10. No. It's the Mac's mic format, which is exactly why you ask instead of hardcoding.

</details>
