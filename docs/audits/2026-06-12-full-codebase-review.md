# Full-codebase review — 2026-06-12

Five parallel reviews over the whole codebase (CaptureKit · App state · TranscriptionKit/DictationKit/AIKit · StorageKit/SharingKit/secrets · Chat/Library/Settings/export/recovery), with API-behavior claims verified against official docs (Apple, Deepgram, AWS SigV4, OpenAI, SQLite). Findings already listed in `docs/audits/2026-06-06-always-on-capture-code-review.en.md` are excluded; their fix status is noted at the end.

**Totals: 0 critical · 6 high · 18 medium · ~23 low.** The six HIGHs cluster on the uncommitted always-on-capture branch and the (not-yet-wired) Deepgram streaming layer.

---

## HIGH — should block merging the always-on-capture branch

### H1. `CaptureSession.start()` partial failure leaks a running ScreenRecorder and wedges the state machine
`Sources/CaptureKit/CaptureSession.swift:616-636` (also `:596`)

New start order is screen → system audio → mic, and the mic bootstrap (`micTask = try await makeMicTask(engine:)`) throws out of `start()` un-caught. When `AudioEngine.start()` fails (stale TCC, no input device, 8-s no-buffer deadline at `AudioEngine.swift:490-516`): `recordingState` is still `.idle` but the ScreenRecorder is capturing and writing screen.mp4, system-audio tasks may be live, and the segment writer is open. `stop()` refuses to clean up (`guard recordingState == .recording || .paused`, `:948`), so the SCStream records until process exit, the AVAssetWriter is never finalized (corrupt screen.mp4), and a retried `start()` deletes the output file out from under the live writer (`ScreenRecorder.swift:217-219`). Same leak via the un-wrapped `try await makeSystemTask(...)` at `:596` (SCKit branch only; device/tap branches are wrapped).

**Fix:** wrap mic and SCKit bootstrap in do/catch and run full teardown (factor `stop()`'s teardown into an internal `teardown()` that ignores `recordingState`) before rethrowing.

### H2. `ScreenRecorder.stop()` throws `.notStarted` whenever `stream == nil` → failed/in-flight mic-recovery restart corrupts screen.mp4 and can leave a zombie SCStream
`Sources/CaptureKit/ScreenRecorder.swift:334-352`, `:639-701`; consumed at `CaptureSession.swift:740-748`

`restartSCStreamForMicRecovery()` sets `stream = nil` then suspends on awaits. Two failure modes:
1. Restart fails (e.g. -3801) → tier-2 calls `recorder.stop()` → `.notStarted` thrown **before** `finishWriting()` — screen.mp4 has no moov atom and is unplayable, contradicting the tier-2 comment "Partial screen.mp4 stays on disk and remains playable".
2. User stops during a restart: `micRecoveryTask?.cancel()` doesn't abort the running restart (no `Task.isCancelled` checks); actor reentrancy lets `stop()` run mid-restart, see `stream == nil`, throw (writer never finalized); the restart then resumes, `startCapture()`s a fresh SCStream and assigns it — an ownerless stream capturing until process exit.

**Fix:** finalize the writer even when `stream == nil` (throw `.notStarted` only when `writer == nil` too); add a stopping/generation flag that the restart checks after each await.

### H3. SCStream outputs on concurrent global queues + unordered Task spawning → no PTS ordering into AVAssetWriter
`Sources/CaptureKit/ScreenRecorder.swift:278-284`, `:390-399`, `:686-692`

`sampleHandlerQueue: .global(qos: .userInteractive)` is a **concurrent** queue — two callbacks for the same output type can run out of order; each spawns an unstructured `Task` (no FIFO guarantee into the actor). Apple's reference code uses dedicated serial queues per output. Non-monotonic PTS puts the AVAssetWriter into `.failed` (only logged, `:462`). The task bag is also unbounded — an actor stall accumulates retained full-res BGRA frames (~30 MB each at Retina).
Docs: https://developer.apple.com/documentation/screencapturekit/scstream/3928168-addstreamoutput · https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/

**Fix:** one private serial DispatchQueue per output type; replace task-per-buffer with a bounded per-type `AsyncStream<SBBox>` consumed by a single actor task.

### H4. Fail-safe auto-stop cancels its own task — the post-stop pipeline runs cancelled and transcription always fails
`App/State/RecorderState.swift:477` (poller calls `stop()`) and `:554` (`stop()` cancels the poller)

The mic-health poller task itself awaits `self.stop()`; inside, `micHealthPollerTask?.cancel()` cancels **the currently executing task**. Cooperative cancellation then makes every downstream cancellation-aware await throw — `URLSession.data(for:)` in WhisperProvider, `asset.load(.duration)`, `Task.sleep` retries. Every fail-safe auto-stop ends in `.failed("Transcription failed: …cancelled")`, violating design invariant I2 ("auto-stops **and finalizes** what was captured"). audio.m4a survives; transcript/summary/FTS/export are lost.
Verified: https://forums.swift.org/t/does-task-cancellation-propagate-to-urlsessiontasks/65041

**Fix:** poller fires `Task { @MainActor in await self.stop() }` and returns; or `stop()` skips cancelling `micHealthPollerTask` when it *is* the current task.

### H5. `stop()` has no reentrancy guard — fail-safe auto-stop racing a user stop corrupts status; a new `start()` can slot into the gap
`App/State/RecorderState.swift:529-586`

`status` flips to `.transcribing` only at line 586, after multiple suspension points. The programmatic fail-safe caller makes a concurrent second `stop()` realistic: caller B passes the guard after A nilled `captureSession`, gets `segments = []`, sets `.failed("No audio captured…")` while A is mid-transcription; during that `.failed` window `start()`'s `guard !status.isBusy` passes and A's eventual `.complete` clobbers the new session's `.recording`.

**Fix:** synchronous in-flight flag (or flip `status` synchronously) as the first statement of `stop()`; gate both `stop()` and `start()` on it.

### H6 (latent — streaming not yet wired). ReconnectingSession retry counter never resets — long sessions die permanently after 5 *total* drops
`Sources/TranscriptionKit/ReconnectingSession.swift:144,188,219`

Doc says "5 **consecutive** failures" but `consecutiveFailures` is threaded through `launchReceiveTask` and never zeroed after a successful reconnect. A 3-h meeting on flaky Wi-Fi that drops 5 times hours apart silently finishes the events stream.

**Fix:** reset the counter on first successful `receive()` of a fresh transport.

### H7. FTS5 search has no `ORDER BY rank` — chat auto-context attaches 3 *arbitrary* sessions, not the most relevant
`Sources/StorageKit/Database.swift:249-267`; consumed at `App/State/ChatState.swift:581` and `App/State/LibraryState.swift:79`

`… MATCH ? LIMIT ?` with no ORDER BY returns rows in arbitrary order per the SQLite FTS5 docs (https://sqlite.org/fts5.html); the `ChatState.swift:604` comment "Preserve FTS ranking order" preserves nothing. With many matches, the LLM gets ~random transcripts as "most relevant"; Library keeps an arbitrary 100.

**Fix:** add `ORDER BY rank` to `searchTranscripts`.

---

## MEDIUM

### CaptureKit
- **C-M1. pause()/resume() leaks capture objects and grows unbounded buffers** — `CaptureSession.swift:838-865`, `ScreenCaptureKitAudio.swift:42-71`, `CoreAudioTap.swift:43-135`. `pause()` cancels tasks but never stops sources; unbounded `AsyncStream` continuations grow ~190 KB/s per PCM source for the whole pause. `resume()` re-`start()`s the same instances: `SCKitAudioCapture.start()` overwrites `self.stream` (leaks a forever-capturing SCStream); `CoreAudioTap.start()` leaks a process tap **and HAL aggregate device** per pause/resume cycle. Fix: stop sources in `pause()` or add self-stop guards + bounded buffering policies.
- **C-M2. After tier-2 demotion, system audio is recorded nowhere** — `CaptureSession.swift:558-599`, `:729-767`. SCKit system-audio fallback is skipped at start because ScreenRecorder owns the HAL; `attemptTier2Fallback()` finalizes the ScreenRecorder and only rewires the mic. From the demotion point, the remote side of the call vanishes silently. Fix: bootstrap SCKit system-audio capture in tier-2 when `systemAudioEnabled`.
- **C-M3. No `SCStreamDelegate` anywhere — externally stopped streams die silently** — `ScreenRecorder.swift:276`, `:684`, `ScreenCaptureKitAudio.swift:65`. `stream(_:didStopWithError:)` (incl. `.userStopped` from the macOS 15 "Stop Sharing" UI, `.systemStoppedStream`) is never observed; video can freeze mid-session with zero signal. Fix: pass a delegate; surface like `screenRecordingError`; treat as terminal in the mic supervisor.

### App layer
- **A-M1. Dictation preflight blocks on `.isBusy` (includes `.transcribing`)** — `DictationState.swift:296-303`. All three hold-to-talk surfaces refuse with "mic owned by active recording" for the whole transcription window (minutes), though `captureSession` is already nil. Fix: match only `.recording`.
- **A-M2. Mic fail-safe sessions are not tagged in the Library** — `RecorderState.swift:572-577`, `:598-602`, `:698`. Design requires the Library row tagged; only a transient in-memory warning is set, no `capture-warning.txt`, `enhancement` stays `.ok`. Fix: mirror the tier-2 sidecar + `.partial` handling for `micFailSafeTriggered`.
- **A-M3. Mic-health notifications unreliable** — `KosmoNotesApp.swift:285-318`. (a) No `UNUserNotificationCenterDelegate` → foreground notifications silenced by default (app is `.regular` whenever Settings/Library/Chat are open). (b) First post races `requestAuthorization` (same-tick) and is dropped. Fix: set a delegate returning `.banner`; request authorization at recording start or chain the first post.

### Transcription / networking (latent until streaming is wired)
- **T-M1. Ring buffer records only *delivered* chunks; outage audio is lost and the replay set is inverted** — `ReconnectingSession.swift:81-93`, `:211-217`. `send` throws before `ringBuffer.append`, so the gap audio never enters the buffer; replay re-sends already-transcribed audio → duplicated segments. Fix: append before send; queue/swallow send failures while reconnect pending.
- **T-M2. Deepgram timestamps reset to 0 on every reconnect** — `ReconnectingSession.swift:208-219` + `DeepgramProvider.swift:145-156`. No session-relative offset tracked → non-monotonic transcript.jsonl. Fix: add per-reconnect offset to parsed segment times.
- **T-M3. No KeepAlive — Deepgram closes NET-0001 after 10 s of silence** — any mute/pause >10 s burns one of the 5 lifetime retries (see H6). Docs: https://developers.deepgram.com/docs/audio-keep-alive. Fix: send `{"type":"KeepAlive"}` every ~5 s of silence.
- **T-M4. `endpointing=true` is not a documented value** — `DeepgramProvider.swift:96`. Docs accept integer ms or `false` (https://developers.deepgram.com/docs/endpointing). Use e.g. `300` or omit.
- **T-M5. `finish()` waits fixed 200 ms instead of draining to Deepgram's `Metadata` flush — tail finals dropped** — `Provider.swift:78-94`, `ReconnectingSession.swift:107-121`. Also nothing passes `{"type":"CloseStream"}` yet, so no server-side flush at all. Docs: https://developers.deepgram.com/docs/close-stream.
- **T-M6. Terminal errors swallowed — "done" indistinguishable from "died"** — `Provider.swift:114-128`, `ReconnectingSession.swift:190-194`. `TranscriptionError.maxRetriesExceeded` is defined and never thrown. Fix: `AsyncThrowingStream` or a `terminalError` property.
- **T-M7. WhisperKitProvider lazy-load reentrancy — engine can load twice** — `WhisperKitProvider.swift:154-193`. Memoize an in-flight `Task<WhisperKit, Error>` instead of the result.
- **T-M8. Partial WhisperKit downloads treated as complete forever** — `WhisperKitModelManager.swift:81-87,119-127`. `isDownloaded` = "any `.mlmodelc` present". Fix: verify the expected component set, or stage + rename on completion.

### Sharing / storage
- **S-M1. SigV4: signed canonical path can differ from the wire path** — `S3Client.swift:44-48`, `:76`, `:178`. URL built with `appendingPathComponent` (leaves sub-delims `+ ( ) ; =` etc. unencoded) while the canonical URI uses strict `awsEncode`. Latent with today's UUID keys; any future user-controlled key breaks with `SignatureDoesNotMatch`. Fix: build the request URL from the same `awsEncode(path, encodeSlash: false)` string (`URLComponents.percentEncodedPath`). Spec: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
- **S-M2. SharingService loads whole artifacts into RAM for one unchunked PUT** — `SharingService.swift:92,99`. 1–4 GB screen recordings double in flight; approaches the 5 GB PUT limit. Fix: `URLSession.upload(for:fromFile:)` + streamed SHA-256, or multipart for video.

### Chat / Library / export
- **L-M1. LibraryState merge throws away both FTS and cosine ranking** — `LibraryState.swift:89-106`. Final `sorted { $0.recordedAt > $1.recordedAt }` reduces semantic search to a date filter. Fix: hydrate into a map, emit in `orderedSids` order.
- **L-M2. ChatState send/sendSnapshot interleave: rollback removes the wrong message** — `ChatState.swift:283-291`, `:353-364`. `removeLast()` on failure can delete a snapshot's message; `sendSnapshot` never rolls back its user turn. Fix: remove by identity; mutually gate on `isSending`/`isSnapshotting`.
- **L-M3. Chat replies silently truncated at 1024 tokens** — `ChatState.swift:374` + `AIKit/Models.swift:87` default. Pass explicit `maxTokens` (4096–8192) for chat.
- **L-M4. MarkdownExporter can request > model output cap** — `MarkdownExporter.swift:73`: `max(2048, input*1.5)` exceeds gpt-4o-mini's 16,384 output cap on long transcripts → API rejects, export silently empty. Clamp per-model.
- **L-M5. WaveformGenerator: stereo input renders only first half; OOB hazard on non-contiguous block buffers** — `WaveformGenerator.swift:55-136`, `:109-119`. Frames vs interleaved samples confusion; `totalLength` read from a `lengthAtOffset` pointer. Fix: divide by `mChannelsPerFrame` (or request mono), use `CMBlockBufferCreateContiguous`.
- **L-M6. `clearAllSessions` empties the recordings root with no active-recording guard** — `LibraryState.swift:190-203`. Deletes the directory of an in-flight recording; `stop()` then fails. Fix: refuse/exclude while recording.

---

## LOW (abridged — see severity/file refs)

- CaptureKit: mute lost during tier-2 fallback window (`CaptureSession.swift:729-767`, `:925-931`); reentrant `enqueueMicBuffer` vs `segmentWriter.close()` re-opens a colliding segment (`SegmentWriter.swift:115-141`); audio `append` result ignored in screen.mp4 path (`ScreenRecorder.swift:467-469`).
- App: duplicate 5-s watchdog in DictationState vs pipeline-internal one (`DictationState.swift:156-171` vs `DictationPipeline.swift:254-288`) — delete the App-layer copy; quit during `.transcribing` abandons post-processing (`KosmoNotesApp.swift:192-205`); Info.plist version stamp churn (audit #12, still present); classifier "tier-2 also failed" branch unreachable after fallback (`CaptureSession.swift:690-693` — stall-to-stop exceeds the I2 budget in that path).
- AIKit: deprecated `max_tokens` → hard 400 on OpenAI o-series (`OpenAIProvider.swift:99`, `OpenRouterProvider.swift:109`) — send `max_completion_tokens`; unbounded `events` buffering + leaked receive task on abandoned sessions (`Provider.swift:36,109-128`) — add `onTermination` closing the transport.
- Storage/sharing: canonical-header space compression missing (`SigV4.swift:159-165`); Keychain read failures silently render keys "not set" and a subsequent empty commit **deletes the real entry** (`AppSettings.swift:708-739`); FTS5 re-index inserts duplicates — no delete-by-sid first (`Database.swift:239-246`); embedding BLOB unpack uses aligned `bindMemory` on possibly-unaligned Data (`EmbeddingProvider.swift:114-120`); RecoveryService has no guard against scanning an in-flight recording (`RecoveryService.swift:59-108`); presign TTL clamped at 168 h while UI promises the configured hours (`S3Client.swift:128` vs `ShareCoordinator.swift:105`, also `:68` not clamped) — validate at settings layer; RecoveryService timeline gap when all `insertTimeRange` calls fail (`RecoveryService.swift:159-174`).
- Other app logic: Makefile uses `cp -r` (= `-RL`, follows symlinks) post-signing — use `ditto` (`Makefile:30`); LibraryState "debounce" is a single `Task.yield()` and stale slow queries can overwrite newer results (`LibraryState.swift:236-246`); WhisperKitDownloadState late progress callback can resurrect `inFlight` (`WhisperKitDownloadState.swift:77-84`); MigrationService sets the migrated sentinel even on failure (`MigrationService.swift:36-45`); timestamp regex accepts "5:75" → 375 s (`ChatState.swift:530-537`); `costCapUSD = 0` silently reset to $1 (`AppSettings.swift:598-599`); SessionRowView hardcodes the recordings path (`LibraryView.swift:193-200`).

---

## Verified clean (checked, no findings)
- SigV4 core: key derivation, string-to-sign, scope, datetime format, UNSIGNED-PAYLOAD presign, query sorting, single-encoding for S3 — spec-correct.
- Secrets: all 8 keys Keychain-only (`.afterFirstUnlockThisDeviceOnly`), logs emit only booleans.
- GRDB: idempotent migrations, WAL via DatabasePool, all queries parameterized; FTS5 search uses `FTS5Pattern(matchingAllTokensIn:)` — no injection/crash.
- TranscriptStore (actor-isolated JSONL append), AtomicWriter (tmp + fsync + rename + dir-fsync) — correct.
- FrameExtractor, cosine similarity (zero-vector guarded), 3-frame/10-frame caps, RecoveryCoordinator, cost-cap modal flow, Deepgram `is_final` parsing, AIKit request construction (Anthropic system param, image blocks, Ollama endpoint validation).

## 2026-06-06 audit status
Fixed in this tree: #2 (auto-stop on first `.dead` + boundary tests), #3 (pause keeps SCStream mic feed), #4 (restart give-up flag — but exposed H2), #5 (badge + notification), #6 (tier-2 sidecar + `.partial`), #7 (shared preflight), #8 (writer-side health counter), #10 (duplicate test target), #11 (DB scoping). Still open: #12 (Info.plist stamp churn — one leftover in tree). #1 single-HAL: CaptureKit side addressed; App side (MicLevelMeter suppression) verified fixed.
