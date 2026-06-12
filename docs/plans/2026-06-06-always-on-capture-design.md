# Always-on capture architecture

**Status:** Draft. Authored 2026-06-06 in response to a recurring "mic dropped at 1.6s, recorded 33 min of system audio + screen with no voice" failure mode reproduced across 5 archived sessions (`413ca54a`, `7a822aea`, `9f857d80`, `b85a5a9b`, `f256d931`).

## Background

The product has FOUR independent surfaces that capture microphone audio:

1. **Meeting / Voice Note recording** (`RecorderState` → `CaptureKit.CaptureSession`)
2. **Dictation** (`DictationState` → `DictationKit.DictationPipeline`)
3. **Live transcription tee** (`RecorderLiveTee` reading from the meeting session)
4. **Push-to-markdown** (`PushToMarkdownState`)

All four sit on top of `AVAudioEngine` for mic capture. Three of them (1, 3, 4) share the same `CaptureSession`-managed engine; dictation runs its own. Whenever a second client of the audio HAL appears mid-session — typically `SCStream` started for screen recording — macOS sends `AVAudioEngineConfigurationChange`. The recovery path on that notification is the failure mode.

## Failure mode

`handleConfigurationChange` calls `engine.start()` which throws `-10868 kAudioUnitErr_FormatNotSupported`. Retries within the same `AVAudioEngine` instance fail with the same error. `recreateEngineAfterRouteChange()` creates a fresh engine, but the new engine **cannot bind to the HAL** while SCStream is actively pulling from it. The supervisor logs "no new buffers for ~3 s, rebuilding from scratch" every 3.3 s for the rest of the session. Audio capture is over; segment writer never gets another mic byte.

User-visible symptom: 1–2 seconds of voice at the start of a meeting recording, then silence under the screen video.

## Invariants

This design commits the codebase to the following invariants. Every PR touching capture must preserve them.

**I1. No silent mic death.** If mic capture stops yielding samples for more than 10 wall-clock seconds while not muted, the user must be notified via a visible UI element within that window (not just `os_log`).

**I2. Hard fail-safe.** If mic capture cannot be restored within 30 seconds, the recording auto-stops and finalizes what was captured. We do **not** continue producing a 33-minute screen.mp4 with silent voice track.

**I3. Single HAL client when both are needed.** When screen recording and microphone are both requested AND the OS supports SCStream microphone (macOS 15+), SCStream is the **only** client of the audio HAL. `AVAudioEngine` is not started.

**I4. Crash-safe segments.** Mic + system audio segments are flushed and fsynced to disk every ≤5 seconds (already true via `SegmentWriter`).

**I5. Health surface is observable.** `CaptureSession` exposes a `Health` snapshot that downstream code (`RecorderState`, menu bar, library) consumes. Health is not derived from log scraping.

## Architecture

### Single capture-health source of truth

`CaptureSession` gets a new public observable property:

```swift
public enum MicHealth: Equatable, Sendable {
    case idle                       // not recording
    case warmingUp                  // first 5 s of capture, supervisor disabled
    case ok                         // buffers flowing
    case muted                      // user pressed mute; not a fault
    case degraded(reason: String)   // no buffers for 5–30 s, recovery in progress
    case dead(reason: String)       // no buffers for >30 s, recovery exhausted
}

public var micHealth: MicHealth { get async }
```

`RecorderState` polls this every 1 s while recording and projects it into `@Observable` UI state. The menu bar shows a coloured dot. Detail view shows a banner.

### Layered fallback

Mic capture picks the highest-tier source available at start, and demotes on failure:

```
Tier 1: SCStream microphone (macOS 15+, when screen-record on)
        ↓ recovery exhausted (3 SCStream restarts failed)
Tier 2: AVAudioEngine fallback (drops system audio in screen.mp4)
        ↓ AVAudioEngine recreate gives up
Tier 3: Stop recording, surface .dead, finalize partial
```

Tier 2 is meaningful: if the SCStream mic dies because the audio device went away (BT disconnect, USB pull), AVAudioEngine on the built-in mic still works. We trade away system audio in screen.mp4 (the SCStream's other purpose) to keep recording voice.

### Auto-stop fail-safe

A new `MicFailSafeMonitor` runs alongside the session:

- Reads `micHealth` every 1 s.
- After 30 s of `.dead` AND user has not dismissed the alert, calls `RecorderState.stop()` with `reason: .micFailSafe`.
- The Library row is tagged with the partial-mic warning so the user knows it's incomplete.

This is the invariant I2. **Better a 60-second valid recording than a 33-minute lie.**

### Dictation hardening

`DictationPipeline` already has its own AVAudioEngine. Three changes:

1. **Pre-flight HAL probe.** Before starting the dictation engine, check if `CaptureSession` is currently using SCStream microphone — if yes, defer to a shared SCStream mic tap rather than starting a parallel AVAudioEngine on the same HAL.
2. **Watchdog with surface.** Mirror the meeting-side `micHealth` and surface it in the dictation HUD so the user sees within 5 s if their voice isn't being captured.
3. **Fail-loud.** If dictation gets <1 s of audio in 10 s of hold time, abort the live adapter and tell the user. Don't silently paste empty string.

## Implementation phases

**Phase 1 — Health surface (foundation).** Add `MicHealth` enum, `micHealth` property on `CaptureSession`, polling in `RecorderState`, menu-bar dot. No behavioural change.

**Phase 2 — Fail-safe auto-stop.** `MicFailSafeMonitor` task in `CaptureSession`. Hooks into `RecorderState.stop()`. Logs reason. Library row tagged.

**Phase 3 — Tier 2 AVAudioEngine fallback for SCStream mic death.** When `ScreenRecorder.micRecoveryGaveUp == true`, `CaptureSession` tears down the SCStream-mic feed and bootstraps `AudioEngine` for the rest of the session. Sample-rate continuity preserved through SegmentWriter's existing per-source counters.

**Phase 4 — Dictation parity.** Apply Phase 1 + 2 to `DictationPipeline`.

**Phase 5 — Tests.** Synthetic tests that simulate `micHealth` transitions and verify auto-stop fires at 30 s. (We cannot test the real -10868 path in CI — TCC blocks SCStream — so integration verification stays manual via `make install` + recording.)

## Out of scope

- Recovering audio from the 5 already-broken sessions. Mic bytes that were never captured cannot be reconstructed. Sessions stay on disk for the user to delete manually.
- Pre-record buffer ("dashcam mode"). Future work.
- Cross-process HAL coordination. macOS doesn't expose this primitive; we just need to be a good citizen ourselves.

## Open question for follow-up

If a user explicitly disables the fail-safe (a hypothetical Settings toggle "let me record anyway, I'll deal with it"), do we honour that? Default answer: no — the invariant is the contract, not a preference. Re-evaluate if a real use case appears.
