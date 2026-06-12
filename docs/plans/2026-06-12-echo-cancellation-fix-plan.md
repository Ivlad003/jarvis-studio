# Echo cancellation fix — implementation guide

**Date:** 2026-06-12 · **Status:** ready to implement (research verified against the tree)
**Problem:** recording a meeting (Google Meet etc.) played through **laptop speakers** puts the
remote voices into the recording twice — once via system-audio capture, once via mic bleed —
producing audible echo in playback and duplicated/garbled words in the transcript. Headphones
avoid it; we want it fixed without headphones.

---

## 1. Root cause (verified)

- Mic and system audio are captured as **separate tracks** (`audio.m4a` track 0 = mic,
  track 1 = system; `SegmentWriter.swift:190-203`, concat keeps the layout —
  `RecoveryService.swift:117-121`).
- Playback mix folds both into screen.mp4 (`ScreenAudioMixer.mixMicInto`,
  `Sources/CaptureKit/ScreenAudioMixer.swift:40-143`, system 0.7 / mic 1.0): the remote voice
  appears twice with ~10–50 ms offset → echo.
- The whole 2-track file goes to batch transcription (`RecorderState.swift:692-695`) → the STT
  hears every remote word twice.
- The live tee receives both sources interleaved as well (`CaptureSession.enqueueMicBuffer` +
  per-source `delivery.enqueue` calls) → live transcript inherits the echo.

**Nothing in the capture path applies echo cancellation.** Confirmed: zero call sites for
`setVoiceProcessingEnabled` in `Sources/` + `App/`.

## 2. Prior art in this repo — read before coding

`Sources/CaptureKit/AudioEngine.swift:337-343` documents a **previous attempt that was rolled
back**: enabling `setVoiceProcessingEnabled(true)` worked, but VoiceProcessingIO's **AGC dropped
mic gain to inaudible levels** and the forced mono-16 kHz format broke the 48 kHz pipeline.

Both rollback reasons are now addressable:

1. **AGC** — macOS 14+ exposes `AVAudioInputNode.isVoiceProcessingAGCEnabled = false`
   (pure AEC without auto-gain). The deployment target is already `.macOS(.v14)` — available
   unconditionally.
2. **Format** — the tap now converts *any* input format to 48 kHz mono Float32 per buffer
   (`AVAudioConverter` in the tap callback, `AudioEngine.swift:684-702`, `ConverterCache`
   at `:995-1020`). A VPIO-forced 16/24 kHz input is just another source rate.

Also relevant: `voiceProcessingOtherAudioDuckingConfiguration` (macOS 14+) — without it, VPIO
may **duck the system audio the user is listening to** (the Meet call itself). Must be set to
minimum ducking.

## 3. Why the obvious fix alone is not enough

In the user's actual scenario (Audio + Screen, macOS 15+) the mic does **not** go through
`AVAudioEngine` — it goes through **SCStream** (`captureMicrophone = true`,
`ScreenRecorder.swift:207-234`), chosen deliberately so SCStream is the *single client of the
audio HAL* (fixes the `-10868` config-change cascade / "mic dies at minute 33" bug — comment in
`CaptureSession.start`). `SCStreamConfiguration` has **no AEC knob**.

So the fix has two halves:
- **(A)** enable VPIO AEC in the `AVAudioEngine` mic path (audio-only mode, macOS 14, tier-2
  fallback);
- **(B)** when echo cancellation is ON and we're in screen mode on macOS 15+, route the mic
  back to the VPIO `AVAudioEngine` (SCStream keeps screen + system audio only).

(B) reintroduces AVAudioEngine next to SCStream. Mitigations that already exist and made this
safe enough: the **start ordering** (screen + system first, ~300 ms HAL settle, then mic engine
— the comment block in `CaptureSession.start` states this "eliminates the race"), the
**buffer-flow supervisor** inside AudioEngine (1 s ticks, 3 s stall threshold, engine recreate),
and the **mic-health supervisor + 30 s fail-safe** in CaptureSession/RecorderState. Note VPIO is
a *different* IO unit (`AUVoiceProcessingIO`, not `AUHAL`), which changes (likely improves) the
contention profile. Treat (B) as the risk-bearing half — it ships behind the same toggle.

---

## 4. Implementation steps

### Step 1 — `AudioEngine.Config` gains the flag

`Sources/CaptureKit/AudioEngine.swift:181-189`:

```swift
public struct Config: Sendable {
    public let sampleRate: Double
    public let channels: AVAudioChannelCount
    public let voiceProcessing: Bool          // NEW: Apple AEC (echo cancellation)

    public init(sampleRate: Double = 48_000,
                channels: AVAudioChannelCount = 1,
                voiceProcessing: Bool = false) { ... }
}
```

### Step 2 — enable VPIO in `AudioEngine.start`

Insert at the exact spot the rollback comment marks (`AudioEngine.swift:335-343`), i.e. right
after `let inputNode = engine.inputNode` and **before** any tap install / `engine.prepare()` /
`engine.start()` (Apple: voice processing can only be toggled on a stopped engine; enabling it
on the input node auto-enables it on the output node):

```swift
let inputNode = engine.inputNode

if config.voiceProcessing {
    do {
        try inputNode.setVoiceProcessingEnabled(true)
        // The two reasons the 2026-05 attempt was rolled back, neutralized:
        inputNode.isVoiceProcessingAGCEnabled = false      // no auto-gain collapse
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min) // don't duck the call audio
    } catch {
        // Non-fatal: fall back to raw capture rather than failing the recording.
        audioEngineLog.error("AudioEngine.start: voice processing unavailable — \(error.localizedDescription, privacy: .public)")
    }
}
```

Replace the old rollback NOTE comment with one sentence explaining the AGC/ducking lines (they
are the load-bearing difference vs the rolled-back attempt).

**Format knock-ons to check while there (all expected benign):**
- The tap reads the live bus format and converts per-buffer — VPIO's 16/24 kHz mono is handled.
- The "24 kHz mono looks like Bluetooth HFP" heuristic (`AudioEngine.swift:443-446`) will
  misfire on VPIO's format — consequence is only a log line + longer first-buffer deadline.
  Optionally gate that heuristic on `!config.voiceProcessing`.
- `SegmentWriter.append` drops non-48 kHz buffers (`SegmentWriter.swift:133-137`) — unaffected,
  conversion happens upstream.

### Step 3 — re-apply VPIO on engine recreation

`recreateEngineAfterRouteChange()` (`AudioEngine.swift:~837-885`) builds a **fresh**
`AVAudioEngine` after fatal route changes. Without re-applying, the first BT-headphones
(un)pair mid-recording silently loses AEC. Insert the same enable block right after
`let newInputNode = newEngine.inputNode` and **before** the format-bind wait loop /
`newEngine.prepare()`.

The in-place tap *reinstall* path (`handleConfigurationChange` → reinstall, same engine
instance) keeps the IO unit, so VPIO persists there — no change needed. Only fresh-engine sites
need the block (today: `start` + `recreateEngineAfterRouteChange`; grep `AVAudioEngine()` in
the file to be sure).

### Step 4 — `CaptureSession`: flag + mic-path decision

1. `CaptureSession.Config` (`CaptureSession.swift:241+`): add
   `public let echoCancellationEnabled: Bool` (default `false`, threaded through `init`).
2. `micAudioEngineConfig` (the helper that builds `AudioEngine.Config`, around `:317-322`):
   pass `voiceProcessing: config.echoCancellationEnabled`. Verify **every** `AudioEngine(`
   creation site gets it — including the **tier-2 fallback** engine in
   `attemptTier2Fallback` (grep `AudioEngine(` in CaptureSession.swift).
3. Replace the inline `scStreamMicEligible` closure in `start()` (currently: screen + mic +
   macOS 15) with a **pure, testable decision** following the repo's
   `Tier2SystemAudioFallbackPlan` pattern — new file `Sources/CaptureKit/MicPathPlan.swift`:

```swift
/// Decides whether the mic should be captured by SCStream (single-HAL path)
/// or by AVAudioEngine. Echo cancellation forces the AVAudioEngine path
/// because SCStream exposes no AEC; the start-order mitigation (screen first,
/// HAL settle, mic engine second) + the AudioEngine supervisors carry the
/// HAL-contention risk that SCStream-mic was originally built to avoid.
enum MicPathPlan {
    static func shouldUseSCStreamMic(screenRecordingEnabled: Bool,
                                     micEnabled: Bool,
                                     echoCancellationEnabled: Bool,
                                     isMacOS15OrNewer: Bool) -> Bool {
        guard screenRecordingEnabled, micEnabled, isMacOS15OrNewer else { return false }
        return !echoCancellationEnabled
    }
}
```

   In `start()`: `let scStreamMicEligible = MicPathPlan.shouldUseSCStreamMic(...)`. When it
   returns `false` in screen mode, the existing code path already falls back to the
   AVAudioEngine mic task (`screenMicStream == nil` branch) — verify the log line still makes
   sense and keep the existing ~300 ms settle before the mic engine bootstraps.

### Step 5 — `AppSettings` toggle

Pattern per existing settings (`AppSettings.swift` `Defaults` enum + `didSet` + `init` line,
e.g. `semanticSearchEnabled` at `:434-435` / `:648`):

```swift
// Defaults enum:
static let echoCancellationEnabled = "echoCancellationEnabled"
// property:
var echoCancellationEnabled: Bool {
    didSet { UserDefaults.standard.set(echoCancellationEnabled, forKey: Defaults.echoCancellationEnabled) }
}
// init (default ON — the speakers scenario is the common failure, headphones are unaffected
// by AEC since there's simply no echo to cancel):
self.echoCancellationEnabled = (UserDefaults.standard.object(forKey: Defaults.echoCancellationEnabled) as? Bool) ?? true
```

Note the `object(forKey:)` presence-check (don't repeat the `costCapUSD = 0` bug from the
2026-06-12 audit).

### Step 6 — `RecorderState` passes it through

Where `CaptureSession.Config` is built in `RecorderState.start` (near the `systemAudioEnabled`
force-enable at `RecorderState.swift:287-292`): add
`echoCancellationEnabled: settings.echoCancellationEnabled`.

`DictationPipeline` is **out of scope** — dictation is the user speaking close-mic; do not
enable VPIO there in this change (its noise suppression can hurt raw dictation audio).

### Step 7 — Settings UI

Settings → Transcription, next to the "System audio source" picker
(`App/Views/Settings/SettingsView.swift:1335-1390` — its doc comment already describes this
exact echo problem and the BlackHole workaround):

```swift
Toggle("Echo cancellation (recommended with speakers)", isOn: $settings.echoCancellationEnabled)
Text("Removes meeting audio picked up by the microphone when playing through speakers. Uses Apple voice processing; slight mic-tone change is normal. Turn off for high-fidelity ambient recording.")
    .font(.caption).foregroundStyle(.secondary)
```

Update the BlackHole help text to mention the toggle as the first-line fix.

### Step 8 — speakers-without-AEC warning (cheap UX guard)

At recording start, if `systemAudioEnabled && !echoCancellationEnabled` and the **default
output device is the built-in speakers**, surface a one-line warning via the existing warning
channel (`screenRecordingWarning` / menu surface). Default-output check (CoreAudio, ~30 lines):
`kAudioHardwarePropertyDefaultOutputDevice` → `kAudioDevicePropertyTransportType` ==
`kAudioDeviceTransportTypeBuiltIn`. Message: *"Playing through speakers — enable Echo
cancellation in Settings → Transcription or use headphones to avoid echo in the recording."*

### Step 9 — live transcript: nothing extra

AEC'd buffers enter `enqueueMicBuffer` upstream of both the SegmentWriter and the live tee, so
the live transcript benefits automatically once Steps 2–4 land.

---

## 5. Tests

1. **`MicPathPlanTests`** (new, pure): SCStream-mic on macOS 15 screen+mic without EC; AVAudio
   path when EC on; AVAudio path on macOS 14 regardless; audio-only never SCStream-mic.
2. **Config plumbing**: `CaptureSession.Config(echoCancellationEnabled: true)` →
   `micAudioEngineConfig.voiceProcessing == true` (expose via a test seam like the existing
   `hasAllocatedCaptureResourcesForTesting` if needed).
3. **AudioEngine CI-safe test**: extend the existing "start throws or succeeds without
   crashing" suite with `voiceProcessing: true` — VPIO can't be asserted in CI (no real HAL),
   but the bootstrap must not crash/hang when it's unavailable.
4. **Manual smoke (the one that actually proves it)** — add to
   `docs/release/v1.0-checklist.md`:
   - Google Meet through **built-in speakers**, Audio+Screen, EC **on** → playback of
     screen.mp4: remote voice appears once, no echo; transcript has no duplicated phrases.
   - Same with EC **off** → echo present (control).
   - EC on, **Meet volume for the user is NOT reduced** while recording (ducking check).
   - Mid-recording: pair/unpair BT headphones → recording survives AND echo stays cancelled
     after the route change (Step 3 check).
   - macOS 14 audio-only with speakers → echo cancelled (Step 2 path).
   - Voice memo with EC on: mic gain normal, not "inaudible" (AGC-off check — the original
     rollback symptom).

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CaptureKit suites),
then `xcodegen generate && make install` for the app target; full `make test` before commit
(baseline: 328 tests green).

---

## 6. Phase 2 (optional, later) — offline AEC for recordings made without VPIO

Because tracks are separate and PTS-aligned, a post-process pass at finalize (before
`provider.transcribe` at `RecorderState.swift:692`) can clean historical/SCStream-mic
recordings: `AVAssetReader` both tracks at 48 kHz mono float → estimate bulk delay by
cross-correlation (system → mic, expect 5–60 ms) → NLMS adaptive filter (vDSP-accelerated,
~1024 taps at 16 kHz working rate) → rewrite track 0. Apple's VPIO **cannot** be used offline
(voice processing requires rendering to a real audio device — manual rendering mode is
unsupported), hence the hand-rolled filter. Pure Swift + Accelerate, no new deps. Ship only if
Phase 1's real-time AEC proves insufficient or users need to clean old recordings.

Adjacent (independent) improvement: **track-aware transcription** — transcribe mic and system
tracks separately and merge with speaker attribution; removes transcript duplication even with
EC off and gives diarization for free.

## 7. Risks & rollback

| Risk | Mitigation |
|---|---|
| (B) reintroduces AVAudioEngine next to SCStream → `-10868` race regression | Start ordering + 300 ms settle already in place; AudioEngine supervisor recreates the engine; mic-health 30 s fail-safe stops-and-finalizes worst-case. Watch the mic-health logs in dogfooding. |
| VPIO changes mic tone / NS too aggressive for some voices | Toggle (Step 5) — user turns it off; default-on is reversible per user. |
| VPIO ducks the user's call audio | Explicit `duckingLevel: .min` (Step 2); manual smoke item covers it. |
| AEC silently lost after route change | Step 3 + dedicated smoke item. |
| `setVoiceProcessingEnabled` throws on exotic devices | do/catch falls back to raw capture; recording never fails because of AEC. |

Rollback = flipping the toggle off (per user) or defaulting it to `false` (one line) — no
architectural debt either way.

## 8. Bookkeeping

- CLAUDE.md: add one line to "Features added" when shipped; no stack-invariant change (pure
  Swift, system frameworks only).
- Design doc: this is a capture-pipeline behavior change — record as a §15 Decision Log row
  (D21) referencing this file when implemented.
