# Fix-status verification - 2026-06-12 full-codebase review

Verification pass over the working tree on branch `develop` against
`docs/audits/2026-06-12-full-codebase-review.md`.

The previous version of this file was stale: it still marked several findings as open after the
fixes had already landed. This refresh records the current implementation state and the validation
evidence collected after the final pass.

## Summary

- **HIGH:** 7/7 fixed.
- **MEDIUM:** 22/22 listed findings fixed.
- **LOW:** all behavior-affecting listed LOW items fixed or reduced to an explicit scope caveat.
- **Remaining caveat:** live hardware/API smoke was not run in this pass. The fixes are covered by
  package tests, app tests, static scans, and code inspection, but not by a real microphone,
  ScreenCaptureKit "Stop Sharing" interaction, live Deepgram stream, live S3 upload, or WhisperKit
  model download.

## HIGH

| # | Status | Evidence |
|---|---|---|
| H1 partial `CaptureSession.start()` failure leaks a running recorder | **Fixed** | Start bootstrap is wrapped in teardown-on-failure; partial mic bootstrap failure has a regression test. |
| H2 `ScreenRecorder.stop()` fails when `stream == nil`; restart race can leave zombie SCStream | **Fixed** | Stop finalizes the writer even without an active stream; restart generation/isStopping guards stop abandoned streams. |
| H3 concurrent SCStream queues and unordered task spawning break PTS ordering | **Fixed** | Dedicated serial queues plus bounded FIFO sample task bag; regression coverage for FIFO and buffer delivery. |
| H4 fail-safe auto-stop cancels its own post-stop pipeline | **Fixed** | Poller dispatches stop through a fresh main-actor task before returning. |
| H5 `RecorderState.stop()` lacks a reentrancy guard | **Fixed** | Synchronous lifecycle transition guard covers start and stop before the first await. |
| H6 `ReconnectingSession` retry counter never resets | **Fixed** | Successful receives reset consecutive failures; retry-budget regression test covers isolated drops. |
| H7 FTS5 search lacks `ORDER BY rank` | **Fixed** | Transcript search orders by FTS rank, and re-indexing removes stale FTS rows before insert. |

## MEDIUM

### CaptureKit

- **C-M1 pause/resume capture leaks and unbounded buffers - Fixed.** Pause now stops every source;
  SCKit/CoreAudio/device capture paths self-stop before restart; PCM streams use bounded
  buffering.
- **C-M2 system audio lost after tier-2 demotion - Fixed.** Tier-2 fallback starts the SCKit
  system-audio fallback when configured, with plan coverage.
- **C-M3 missing SCStreamDelegate - Fixed.** SCStream delegates are installed for recorder and
  system-audio streams; external stops surface through the capture error path.

### App layer

- **A-M1 dictation preflight blocks during `.transcribing` - Fixed.** Preflight now blocks only
  while an actual recording owns capture.
- **A-M2 mic fail-safe sessions untagged in Library - Fixed.** Mic fail-safe writes the warning
  sidecar and marks the session as partially enhanced.
- **A-M3 mic-health notifications unreliable - Fixed.** Notification delegate is installed and the
  first post is chained behind authorization.

### Transcription / networking

- **T-M1 outage audio lost from ring buffer - Fixed.** Audio is appended before transport send and
  retained for replay when a write fails.
- **T-M2 Deepgram timestamps reset after reconnect - Fixed.** Reconnect timestamp offsets preserve
  session-relative segment times.
- **T-M3 no Deepgram KeepAlive - Fixed.** Live websocket paths now send KeepAlive during silence.
- **T-M4 undocumented `endpointing=true` - Fixed.** Deepgram endpointing is sent as an integer ms
  value.
- **T-M5 fixed 200 ms finish drain / missing CloseStream - Fixed.** Finish sends CloseStream and
  drains terminal server frames instead of relying on only a short fixed delay.
- **T-M6 terminal errors swallowed - Fixed.** Event streams are throwing streams and retry
  exhaustion surfaces as a terminal error.
- **T-M7 WhisperKit lazy-load reentrancy - Fixed.** Provider load is memoized through an in-flight
  task, not only the completed result.
- **T-M8 partial WhisperKit downloads treated complete - Fixed.** Downloads use in-progress and
  completion markers so partial folders are not accepted as complete.

### Sharing / storage

- **S-M1 SigV4 signed path differs from wire path - Fixed.** S3 request URLs use the same AWS path
  encoding as canonical signing.
- **S-M2 whole artifact loaded into RAM for PUT - Fixed for sharing artifacts.** Sharing uploads now
  use file-backed upload paths with streaming SHA-256 instead of loading large artifacts into
  memory.

### Chat / Library / export

- **L-M1 LibraryState drops FTS/cosine ranking - Fixed.** Hydrated records preserve relevance
  order.
- **L-M2 ChatState send/sendSnapshot rollback race - Fixed.** Send paths are mutually gated and
  rollback removes the failed user turn by identity.
- **L-M3 chat replies truncated at 1024 tokens - Fixed.** Chat uses an explicit roomier response
  budget.
- **L-M4 MarkdownExporter can exceed model output cap - Fixed.** Output token requests are clamped
  with a floor and ceiling.
- **L-M5 WaveformGenerator stereo/OOB hazards - Fixed.** Interleaved stereo is averaged correctly
  and partial trailing samples are ignored.
- **L-M6 clearAllSessions has no active-recording guard - Fixed.** Library clearing is refused
  while a recording owns the recordings root.

## LOW

Fixed items from the LOW section:

- Tier-2 fallback preserves the pre-fallback mute state.
- `SegmentWriter` has a persistent closed state; late appends after close are ignored.
- Screen/audio append failures are logged instead of silently ignored.
- The duplicate App-layer dictation watchdog was removed; `DictationPipeline` owns the watchdog.
- Quitting while transcribing waits for the post-stop pipeline before terminating.
- Debug builds no longer stamp `App/Info.plist`; CFBundleVersion stamping is Release-only.
- Tier-2-failed classification is wired so failed fallback boot does not reset the I2 stop budget.
- OpenAI and OpenRouter chat requests use `max_completion_tokens`; Anthropic/Ollama paths keep
  `max_tokens` because those APIs expect it.
- Live transcript event streams are bounded, throwing, and close transport through termination.
- SigV4 canonical headers compress sequential whitespace.
- AppSettings tracks Keychain read failures and skips destructive empty commits after a read
  failure.
- Embedding BLOB unpack avoids unaligned `Data.bindMemory`.
- Recovery scanning can exclude active session IDs, and timeline insertion advances only after
  successful segment insert.
- Presign TTL is clamped to the S3 SigV4 maximum at the coordinator boundary.
- AtomicWriter surfaces parent fsync failures and removed the dead catch path.
- Install uses `ditto` instead of `cp -r`.
- Library debounce uses generation guarding so stale slow queries cannot overwrite newer results.
- WhisperKitDownloadState ignores late progress from older generations.
- MigrationService sets the migrated sentinel only after all required steps succeed.
- Timestamp parsing rejects impossible minute/second values.
- `costCapUSD = 0` is preserved instead of reset to the default.
- Library rows resolve session paths through the session store instead of hardcoded recordings-root
  assumptions.
- Dictation sample-count naming now matches the value being tracked.
- LiveTranscriptEngine test fixtures zero-fill synthetic PCM, removing the previous SIGBUS-prone
  uninitialized-audio test input.

## Scope caveats

- **Hardware and live-service smoke not run:** this pass did not drive a real microphone,
  ScreenCaptureKit external stop, live Deepgram websocket, live S3 upload, or WhisperKit model
  download. The app and package tests cover the code paths with seams and local fakes.
- **`Data(contentsOf:)` remains in unrelated small/inline paths:** the sharing-artifact upload path
  no longer loads screen recordings into memory. Batch/inline audio providers and small JSON or
  thumbnail reads still use `Data(contentsOf:)` intentionally because they are not the S-M2 sharing
  artifact path.
- **`max_tokens` remains where correct:** Anthropic, Ollama, settings probes, and internal agent
  request shapes still use `max_tokens`. The deprecated OpenAI/OpenRouter chat fields were changed
  to `max_completion_tokens`.
- **Original audit line numbers are now stale:** the files were edited heavily; this document tracks
  finding IDs rather than preserving old line references.

## Verification

Fresh verification from this pass:

- `git diff --check` - passed.
- `xcodegen generate` - passed.
- `plutil -lint App/Info.plist` - passed.
- `swift test --filter 'SegmentWriterTests.appendAfterCloseIsIgnored|RecoveryServiceTests.scanSkipsActiveSessionIDs'` - passed.
- `swift test --filter 'engine_tick_transcribes_and_merges_result' --no-parallel` - passed after the synthetic PCM fixture was zero-filled.
- `swift test --filter '^TranscriptionKitTests\\.' --no-parallel` - passed, 80 tests in 18 suites.
- `make test` - passed, 339 tests in 69 suites; one FTS performance test is intentionally skipped unless `JN_RUN_PERF=1`.
- `xcodebuild test -scheme KosmoNotes -destination 'platform=macOS' -only-testing:KosmoNotesTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=` - passed; Swift Testing reported 32 tests in 10 suites.

Targeted regressions that were also run during the fix sequence:

- OpenAI/OpenRouter/OpenRouterAudio request serialization tests.
- SigV4 canonical header and path tests.
- Embedding unaligned-float tests.
- WhisperKit model-manager and provider-load tests.
- Deepgram provider, reconnect, retry-budget, timestamp-offset, KeepAlive, CloseStream, and terminal-error tests.
- AtomicWriter and RecoveryService tests.
- CaptureKit task-bag, PCM-buffer stream, SCStream delegate, mic converter, tier-2 fallback, and capture-session tests.
- App tests for chat behavior, markdown export, library/share, settings cost cap, migration, share TTL, waveform generation, recovery coordinator, and WhisperKit download state.

## Final state

No source-code audit findings from `docs/audits/2026-06-12-full-codebase-review.md` remain open in
this local verification pass. Release readiness still needs manual smoke on real capture hardware
and live provider credentials.
