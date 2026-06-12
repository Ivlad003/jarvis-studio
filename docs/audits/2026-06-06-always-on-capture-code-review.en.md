# Always-On Capture Code Review

Date: 2026-06-06
Scope: current working tree for the always-on capture / mic-health changes. This is a review artifact only; no production code was changed.

## Recommendation

REQUEST CHANGES.

The automated tests pass, but the implementation does not yet satisfy the capture invariants in `docs/plans/2026-06-06-always-on-capture-design.md`. The main blockers are the still-broken single-HAL contract, a fail-safe that can take about 60 seconds instead of 30 seconds, and degraded capture states that are either not visible enough or not persisted into the library/source-of-truth layer.

Independent review lanes agreed on the result:

- Code-review lane: REQUEST CHANGES.
- Architecture lane: BLOCK.

## Verification Evidence

- `make test` passed: 297 tests in 60 suites.
- `xcodebuild test -scheme KosmoNotes -destination 'platform=macOS' -only-testing:KosmoNotesTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=` passed: 15 app tests in 2 suites.
- The Xcode app-test run still emitted duplicate Objective-C class warnings for package modules loaded both from package frameworks and the app debug dylib.
- The Xcode app-test run also emitted a SQLite lifecycle warning while deleting a temp test database still in use.

Not verified: real macOS 15+ ScreenCaptureKit microphone behavior with TCC permissions and an installed app build. The design doc explicitly keeps that path as manual integration verification.

## High Severity

### 1. Screen + mic mode still violates the single-HAL invariant

Evidence:

- The design requires SCStream to be the only HAL client on macOS 15+ when screen and microphone are both requested: `docs/plans/2026-06-06-always-on-capture-design.md:26-30`.
- `RecorderState` forces system audio on whenever screen recording is selected: `App/State/RecorderState.swift:265-273`.
- `CaptureSession` starts `ScreenRecorder` with `captureSystemAudio: true` and `captureMicrophone: scStreamMicEligible`: `Sources/CaptureKit/CaptureSession.swift:463-470`.
- The same start path then starts a second system-audio capture branch whenever `config.systemAudioEnabled` is true: `Sources/CaptureKit/CaptureSession.swift:495-539`.
- `RecorderState` also starts `MicLevelMeter` for every recording: `App/State/RecorderState.swift:400-406`.
- `MicLevelMeter` explicitly creates a second `AVAudioEngine`: `App/State/MicLevelMeter.swift:8-10`, `App/State/MicLevelMeter.swift:22-45`.

Impact:

On macOS 15+ screen + mic recordings, the code can still create multiple HAL clients: SCStream mic, SCStream/system-audio capture, and a separate `AVAudioEngine` for the UI meter. This undermines the core fix for the mid-session mic loss described in the design.

Recommended fix:

Make the capture source graph explicit. In SCStream-mic mode, feed both recording and UI level data from the same SCStream microphone path, and do not start `MicLevelMeter` or a parallel system-audio path unless the design is updated and the multi-client behavior is proven safe.

### 2. The 30-second fail-safe is effectively double-counted

Evidence:

- The design requires auto-stop if microphone capture cannot be restored within 30 seconds: `docs/plans/2026-06-06-always-on-capture-design.md:28`.
- `CaptureSession` waits until the classifier reports `.dead`, based on the stalled `sinceLastBuffer` clock: `Sources/CaptureKit/CaptureSession.swift:600-653`.
- `RecorderState` then starts a new `deadSince` timer only after it first observes `.dead`, and waits another 30 seconds before stopping: `App/State/RecorderState.swift:408-436`.

Impact:

A plain mic stall can run for roughly 60 seconds from the last microphone sample before auto-stop. That conflicts with the stated invariant and delays user protection.

Recommended fix:

Expose the original stall start time or elapsed stall seconds from `CaptureSession`, then let `RecorderState` stop when total stall duration reaches the invariant. Alternatively, make `.dead` mean "stop now" and keep the 30-second threshold entirely inside `CaptureSession`.

### 3. Pause/resume drops the SCStream microphone writer task

Evidence:

- `pause()` cancels feed tasks and closes the segment writer: `Sources/CaptureKit/CaptureSession.swift:716-727`.
- `cancelFeedTasks()` cancels `micTask`: `Sources/CaptureKit/CaptureSession.swift:842-847`.
- `resume()` recreates `micTask` only when `audioEngine` exists: `Sources/CaptureKit/CaptureSession.swift:734-753`.
- In SCStream-mic mode, `audioEngine` is intentionally nil because mic samples come from `ScreenRecorder`: `Sources/CaptureKit/CaptureSession.swift:555-570`.

Impact:

After pausing and resuming a macOS 15+ screen + mic recording, SCStream may keep producing mic buffers, but no task drains them into the new `SegmentWriter`. That can create silent or incomplete mic segments after resume.

Recommended fix:

Track the active mic source as an explicit enum and recreate the correct feed task on resume. For the SCStream path, either reconnect the existing SCStream mic stream to the new writer or stop/restart screen capture with a new mic stream.

### 4. Recovery restart failures can leave the system stuck without fallback

Evidence:

- `ScreenRecorder.micRecoveryTick` exits early whenever `stream == nil` and does not set `micRecoveryGaveUp`: `Sources/CaptureKit/ScreenRecorder.swift:516-526`.
- `restartSCStreamForMicRecovery()` sets `stream = nil` after stopping the old stream: `Sources/CaptureKit/ScreenRecorder.swift:564-571`.
- Several restart failure paths log and return without setting `micRecoveryGaveUp`: `Sources/CaptureKit/ScreenRecorder.swift:573-584`, `Sources/CaptureKit/ScreenRecorder.swift:614-623`.
- `CaptureSession` only attempts tier-2 fallback when `recorder.micRecoveryGaveUp` is true: `Sources/CaptureKit/CaptureSession.swift:625-641`.

Impact:

If SCStream restart fails after the old stream is cleared, the recovery supervisor can idle with `stream == nil` and `micRecoveryGaveUp == false`. The tier-2 fallback may never run, and the fail-safe path may be delayed or bypassed.

Recommended fix:

Make restart return a success/failure result. On restart failure, set `micRecoveryGaveUp = true` or surface an explicit terminal recovery error that `CaptureSession` consumes immediately.

### 5. The mic-health warning is not visible unless the menu is opened

Evidence:

- The design requires a visible UI element within 10 seconds, not just logs: `docs/plans/2026-06-06-always-on-capture-design.md:26`, `docs/plans/2026-06-06-always-on-capture-design.md:55`.
- The menu item is hidden by default and lives inside the menu: `App/KosmoNotesApp.swift:278-286`.
- `updateMicHealthItem` is only called from `menuNeedsUpdate`: `App/KosmoNotesApp.swift:763-785`, `App/KosmoNotesApp.swift:843-855`.
- `RecorderMenuPresenter` only formats the menu title; it does not drive a status item or notification: `App/State/RecorderMenuPresenter.swift:24-32`.

Impact:

A user who does not open the menu may not see degraded or dead mic state within the required 10-second window. This is not enough to satisfy "no silent mic death."

Recommended fix:

Bind `RecorderState.micHealth` to an always-visible status item badge, banner, notification, or recording window surface. The menu row can remain a secondary detail surface.

## Medium Severity

### 6. Tier-2 screen demotion is not consumed or persisted

Evidence:

- `CaptureSession` exposes `tier2DemotedScreenRecording`: `Sources/CaptureKit/CaptureSession.swift:383-389`.
- Tier-2 fallback sets the flag after stopping the screen recorder: `Sources/CaptureKit/CaptureSession.swift:656-684`.
- The current working tree has no consumer for that flag outside `CaptureSession`.
- `RecorderState` only writes a warning when `micFailSafeTriggered` is true: `App/State/RecorderState.swift:512-524`.
- The design says the library row must be tagged with a partial-mic warning: `docs/plans/2026-06-06-always-on-capture-design.md:75-77`.
- The existing library partial marker is for optional post-processing failures, and its help text says recording and transcript are intact: `App/Views/Library/LibraryView.swift:146-154`.

Impact:

If tier-2 fallback succeeds, the recording can continue audio-only after screen capture is demoted, but the user may not get a durable library warning that screen video stopped mid-session. The source-of-truth sidecars do not appear to carry that capture warning.

Recommended fix:

Persist capture warnings separately from enhancement warnings, for example in a capture-status sidecar or database field. Have `RecorderState` consume `tier2DemotedScreenRecording` during finalization and update the Library UI with capture-specific copy.

### 7. Dictation hardening is only partial and not shared across hold-to-talk clients

Evidence:

- The design calls for a pre-flight HAL probe or shared SCStream mic tap, watchdog surface, and fail-loud behavior: `docs/plans/2026-06-06-always-on-capture-design.md:81-87`.
- `DictationState` adds a 5-second zero-frame watchdog after `DictationPipeline.startRecording()`: `App/State/DictationState.swift:146-164`.
- `DictationPipeline` still starts its own `EngineBox` / `AVAudioEngine` directly: `Sources/DictationKit/DictationPipeline.swift:198-215`.
- Other hold-to-talk entry points start `DictationPipeline` without the watchdog: `App/State/PushToMarkdownState.swift:118-147`, `App/State/AgentHotkeyState.swift:129-160`.
- The app installs dictation, push-to-markdown, and agent hotkeys independently: `App/KosmoNotesApp.swift:420-442`.

Impact:

The main dictation path can fail loudly after five seconds, but it can still start a parallel HAL client during an active SCStream-mic recording. Push-to-Markdown and Agent hotkey paths do not get the same watchdog behavior.

Recommended fix:

Move mic-health/watchdog behavior into `DictationPipeline` or a shared hold-to-talk coordinator. Add an active-recording mic ownership check so dictation either shares the SCStream mic path or refuses to start while that path owns the HAL.

### 8. The health counter can say "ok" before samples reach disk

Evidence:

- `ScreenRecorder` creates the mic stream with `.bufferingNewest(100)`, which can drop old buffers if downstream stalls: `Sources/CaptureKit/ScreenRecorder.swift:178-183`.
- `CaptureSession` reads health from `ScreenRecorder.micFlowSnapshot`: `Sources/CaptureKit/CaptureSession.swift:706-713`.
- The actual write to disk happens later in `makeScreenRecorderMicTask`: `Sources/CaptureKit/CaptureSession.swift:880-900`.

Impact:

Mic health currently tracks SCStream source delivery, not successful segment writes. If the async stream drops buffers or `writer.append` fails repeatedly, the UI can still show healthy input while the recording sidecar is losing microphone audio.

Recommended fix:

Track a writer-side mic counter or append-failure state and feed that into `MicHealth`. The invariant is about voice reaching the recording, not only SCStream producing buffers.

### 9. Tests cover helper state, not the integration contracts

Evidence:

- New tests cover initial `.idle` and enum equality: `Tests/CaptureKitTests/CaptureSessionTests.swift:418-441`.
- The design asks for synthetic tests that simulate `micHealth` transitions and verify auto-stop at 30 seconds: `docs/plans/2026-06-06-always-on-capture-design.md:99`.

Impact:

The current passing tests do not prove the single-HAL path selection, stop timing, tier-2 demotion behavior, pause/resume behavior, restart failure path, or library warning persistence.

Recommended fix:

Add deterministic seams around mic-flow snapshots, screen recorder recovery status, source graph selection, and `RecorderState` fail-safe time. Then test the invariants without relying on real TCC/SCStream.

### 10. The app-test target is defined twice and the test run loads duplicate classes

Evidence:

- `project.yml` defines `KosmoNotesTests` once at `project.yml:125-143`.
- It defines `KosmoNotesTests` again at `project.yml:168-187`, adding a direct `TranscriptionKit` package dependency.
- The app-test run emitted duplicate Objective-C class warnings for package classes loaded both from package frameworks and `KosmoNotes.debug.dylib`.

Impact:

The warnings explicitly say this can cause spurious casting failures and mysterious crashes. Even though tests pass today, this makes app-test behavior less trustworthy.

Recommended fix:

Collapse the duplicate target definition and avoid linking the same package products through both the hosted app and the test bundle. If tests need direct package access, prefer a separate non-hosted test target or test seams exposed through the app target.

## Low Severity

### 11. SQLite temp files are deleted while the database is still open in a test

Evidence:

- `LibraryShareLogicTests` defers removal of `tmpDir` while `db` and `store` are still alive: `AppTests/LibraryShareLogicTests.swift:48-56`.
- `AppDatabase` owns a `DatabasePool` with no explicit close method: `Sources/StorageKit/Database.swift:110-123`.
- The Xcode test run emitted a SQLite warning about unlinking a vnode while still in use.

Impact:

This is test hygiene, but it can hide real database lifecycle problems or make future failures look unrelated.

Recommended fix:

Release or explicitly close the database before deleting the temp directory. If GRDB close is not available through the current wrapper, scope the database/store in a nested block and delete after the references are gone.

### 12. Generated version stamp noise remains in the working tree

Evidence:

- `App/Info.plist` has a dirty `CFBundleVersion` stamp in the current working tree.
- Repo instructions say build/test stamp churn should be reverted unless a version bump was intended.

Impact:

This is not a runtime bug, but it creates review noise and can hide meaningful release metadata changes.

Recommended fix:

If no release/version bump is intended, revert only the generated `CFBundleVersion` change. Do not touch unrelated user changes.

## Stop Condition

Do not ship or merge the always-on capture change until the high-severity issues are fixed and verified with:

- Deterministic unit tests for source graph selection, mic-health transitions, tier-2 fallback, pause/resume, and 30-second stop timing.
- App-level tests for persisted capture warnings.
- Manual installed-app smoke on macOS 15+ with screen + mic + system audio, including pause/resume and a forced/reproduced mic stall where possible.
