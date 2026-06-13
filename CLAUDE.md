# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**v1.0 feature-complete UNVERIFIED — manual smoke pending.** All 18 acceptance criteria are wired in code; release path checklist is in `docs/release/v1.0-checklist.md`. The Swift Package exists, the menu-bar app records → transcribes live (Deepgram WebSocket) or batch → AI-summarizes → indexes (FTS5 + optional embeddings) → opens for chat (vision-capable with screen.mp4) → exports → shares to S3. Local validation via `make test` exits 0 (375 tests in 78 suites). Read `docs/plans/2026-05-02-jarvis-note-design.md` first — it is the canonical source of truth for all architectural decisions, and `.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` for the phase-by-phase plan.

**Features added (latest session — 2026-06-13):**
- **Dual-source live transcript (You / Them).** Live transcription runs two window engines — mic tagged "You", system/app audio tagged "Them" — merged into one speaker-labeled timeline via `LiveTranscriptState.merging(you:them:)`. Each source has its own `RecorderLiveTee` (single-format CAF), routed by per-sink `SourceFilteredPCMSink` behind a `FanOutPCMSink` in `RecorderState.start`. UI/chat render `You:`/`Them:` via `labeledStableText`. Deepgram streaming stays mic-only pending a dual-stream follow-up. Runtime needs on-device verification (no mic/system audio in CI).
- **Echo cancellation FORCED OFF + toggle disabled (reverses the 2026-06-12 D21 default).** VoiceProcessingIO is a duplex unit that only feeds the input tap while an output render path is rendering; this input-tap-only engine has none, so AEC-on makes the mic tap never fire → zero captured audio. **Confirmed on-device 2026-06-13:** AEC-on → empty `segments/`, no `audio.m4a`; AEC-off → full `audio.m4a` + segments + transcript + summary. Adding the output path (`connect(input→mainMixer)`) throws an uncatchable CoreAudio `-10868` on real AUHAL/aggregate formats. `AppSettings.init` now forces `echoCancellationEnabled = false` regardless of stored value (keeps capture / `MicPathPlan` / warnings consistent) and the Settings toggle is `.disabled(true)`. Re-enable in `AppSettings` **and** `SettingsView` once a real VPIO fix is verified on a device. See the `NOTE` in `AudioEngine.applyVoiceProcessingIfNeeded`.

**Features added (2026-06-12):**
- **Speaker echo cancellation.** `AudioEngine` enables Apple VoiceProcessingIO with AGC disabled and minimum other-audio ducking; `CaptureSession` routes screen-mode mic capture through AVAudioEngine when AEC is on because SCStream has no AEC knob. See design decision D21. **(As of 2026-06-13 this defaults OFF — see above; the VPIO path never delivered audio.)**
- **Screen recording non-fatal fallback.** `CaptureSession.start` now catches `ScreenRecorder.start` errors instead of propagating them. Audio recording always continues. `screenRecordingError` is exposed so `RecorderState` can surface a user-facing alert. On macOS 15+/26, `SCShareableContent` throws `-3801 userDeclined` even when TCC is granted in System Settings (TCC identity changed after signing). The alert offers three actions: open System Settings, run `tccutil reset ScreenCapture dev.kosmonotes.studio` + re-grant ("Fix Permission"), or continue audio-only.
- **Permission check corrected.** `KosmoNotesApp.checkPermissionsOnStartup()` uses `CGPreflightScreenCaptureAccess()` on every launch. The earlier `SCShareableContent` async probe was removed — it gave false positives (threw `-3801` even when permission was granted) on macOS 15+/26.
- **Logs Since filter auto-refresh.** `LogsTab` now calls `refresh()` via `onChange(of: sinceMinutes)` — switching between Last 5 min / 30 min / 2 h / 24 h immediately reloads entries without requiring a manual "Refresh" button click.
- **`make install` rm-rf fix.** Makefile now runs `rm -rf /Applications/KosmoNotes.app` before `cp -r` to prevent stale `Info.plist` overlay on reinstall.
- **Live transcription hold-to-talk adapter.** `LiveTranscriptionHoldToTalkAdapter` debounces PTT key events and drives `LiveTranscriptionState` start/stop. Wired into `RecorderView` PTT button.
- **ScreenRecorder concurrency fix.** Frame capture loop uses a bounded serial actor queue with drain semantics. Frame rate: 15 fps / 1 Mbps defaults for sustainability on long calls.
- **Signed builds via `make install`.** Build (unsigned) → `codesign --force --deep --sign <cert-hash>` → `rm -rf` + `cp -r` to `/Applications`. Cert: `Apple Development: Vladyslav Kosmach (7CP69K73N6)`, Team `Q7ZGRSDQSQ`. TCC permissions survive reinstalls.

**Features added 2026-05-03 (v1.0 scope expansion past the original v1.1 cut):**
- **AC-6 startup gate.** `KosmoNotesApp.checkMinimumOS` surfaces a `<12.3` "upgrade" modal and a `<14.0` "core features disabled" warning.
- **Voice Note Mode** (third capture mode) with `freeform / task / journal / checklist` prompt templates. Hotkey ⌘⇧N. Settings → Voice Note tab.
- **Global hotkeys** (⌘⇧R Meeting · ⌘⇧N Voice Note · ⌘⇧L Library) registered via `KeyboardShortcuts`; rebindable in Settings → Hotkeys.
- **Cost-cap enforcement modal.** `RecorderState.confirmCostOverage` replaces the silent skip with an "Increase to $X / Cancel" alert.
- **OpenRouter LLM provider** (`Sources/AIKit/OpenRouterProvider.swift`) — OpenAI-compat with `HTTP-Referer` + `X-Title` headers. Wired into `RecorderState`, `DictationState`, `ChatState`, Settings tab.
- **Embedding semantic search.** `OpenAIEmbeddingProvider` (`text-embedding-3-small`, 1536 dims). Schema migration v2 adds `session_embeddings(sid, vector BLOB, model, indexed_at)`. `LibraryState.refresh` merges FTS5 hits with cosine top-K. Toggleable in Settings → AI Providers.
- **S3 sharing** (`Sources/SharingKit/`). Hand-rolled AWS Sig V4 (no aws-sdk dep). `S3Client.putObject` + `S3Client.presignedGetURL`. Compatible with AWS / R2 / B2 / MinIO. Library detail view gets a "Share" button. Settings → Sharing tab.
- **Per-process Core Audio Tap** (`Sources/CaptureKit/CoreAudioTap.swift`, macOS 14.4+). Settings → Transcription "System audio source" picker. Falls back to SCKit on failure or older OS.
- **Waveform thumbnails.** `WaveformGenerator` actor. `AVAssetReader` → bucket-average → `CGContext` PNG cached at `<sid>/thumb.png`. Rendered in `SessionRowView`.
- **SleepAssertion wired** into `RecorderState.start/stop/teardown` so `IOPMAssertion` lifecycle matches the active recording.
- **`applicationWillTerminate` hook** flushes mid-record on Cmd+Q (was relying on Recovery service before).

Phase A Week 2 (TranscriptionKit + recovery):
- `Sources/StorageKit/RecoveryService.swift` — orphan-segment scanner + `AVMutableComposition` + `AVAssetExportSession` (`AppleM4A` preset) concat. Replaces the design-doc's bundled-ffmpeg approach (AAC-in-`.m4a` is natively concatenable).
- `Sources/TranscriptionKit/{Models,WebSocketTransport,Provider,DeepgramProvider,TranscriptStore}.swift` — happy-path Deepgram pipeline: typed config / segments / errors, transport abstraction (`URLSessionWebSocketTransport` + injectable mock), `TranscriptionSession` actor with `events: AsyncStream<TranscriptSegment>`, Deepgram URL builder + JSON `Results` parser, `TranscriptStore` actor writing JSONL + atomic TXT.
- `Sources/TranscriptionKit/ReconnectingSession.swift` — resilient layer on top of the happy-path session: 5-s audio ring buffer, exponential backoff (0.25→0.5→1→2→4 s, capped, max 5 retries), stable `events` stream across reconnects, injectable `ReconnectClock` for tests. `DeepgramProvider.openResilientSession(config:clock:)` is the production entry point; `openSession(config:)` remains for tests/single-shot use.

Phase A Week 3 (StorageKit DB + session store):
- `Sources/StorageKit/Database.swift` — GRDB-backed schema v1: `sessions` (id, recorded_at, duration_secs, mode, language, status) + `transcripts_fts` FTS5 virtual table. WAL journal mode. Idempotent migration via `DatabaseMigrator`.
- `Sources/StorageKit/SessionStore.swift` — actor that creates `<root>/<sid>/`, writes `session.json` atomically via `AtomicWriter`, inserts/updates DB rows, indexes transcript text into FTS.

### Encoder deviation: AAC, not Opus

The plan and design doc originally specified Opus 96 kbps mono in an Ogg or `.opus` container. Implementation pivoted to **AAC 96 kbps mono in `.m4a`** because `AVAudioConverter` Opus output requires macOS 14+ and the deployment target is macOS 12.3+. AAC is universally supported, plays in QuickTime/Safari natively, requires zero extra dependencies. File size is roughly 2× larger than equivalent Opus — acceptable for v1.0.

Knock-on effect: **`RecoveryService` no longer needs a bundled `ffmpeg` subprocess.** AAC segments in `.m4a` can be concatenated losslessly via `AVMutableComposition` + `AVAssetExportSession` with `AVAssetExportPresetPassthrough` — no re-encode, no 30 MB ffmpeg static binary. The §8 boundary item ("ffmpeg vs Ogg-stdlib concat") is retired. Bundle stays well under the 15 MB AC-16 budget.

If Opus is required in a future version, raise the deployment target to macOS 14+ and switch `AVAudioFormat` settings to `kAudioFormatOpus`.

Open the design doc before answering any "how do I implement X" question. Every concrete decision (capture API, transcription provider, encoding format, IPC shape, file layout, dependency lifecycle) is recorded there. Open questions are listed in §16; everything else is decided.

## Pivot history

This repository started as **Jarvis Studio** — a cross-platform Tauri/iced screen recorder in Rust. After ~5 weeks of work (37 passing tests, working v0.1.1) the scope was pivoted on 2026-05-02 to a smaller voice-first macOS-native product called **Jarvis Note**.

### 2026-05-02 (evening): Screen recording reinstated

The original Jarvis Note pivot deferred screen recording. The user reversed that
decision after using the v0 audio-only build — the chat is much more useful when
it can answer "what was on screen at minute X" by extracting a frame and sending
it to a vision-capable model.

What changed:
- `Sources/CaptureKit/ScreenRecorder.swift` adds SCStream-based screen + system
  audio capture, writing to `<sessionDir>/screen.mp4` via AVAssetWriter (H.264
  + AAC, 24 fps, 4 Mbps).
- `AppSettings.RecordingMode` toggle: Audio only / Audio + Screen.
- `AIKit.ChatMessage` now has structured parts (text + image), Anthropic + OpenAI
  providers handle base64 image blocks.
- `ChatState` parses timestamp references in user messages, extracts frames from
  screen.mp4 of attached sessions via `FrameExtractor`, attaches them as image
  parts. Cap: 3 frames/send.

Stack invariant updates:
- The "no screen recording" line in §"Stack invariants" is REMOVED.
- Recording mode is configurable in Settings → Transcription; audio-only stays the default.

### 2026-05-04: WhisperKit reinstated (local transcription)

Original design forbade on-device transcription for v1.0 (cloud-only invariant).
The user reversed that on 2026-05-04 after using v0.0.2 — the cost + privacy
case for "I want to dictate without sending audio anywhere" became compelling
enough to revisit.

What changed:
- `Sources/TranscriptionKit/WhisperKitProvider.swift` — `BatchTranscriptionProvider`
  conforming actor that wraps WhisperKit. Lazy-loads the CoreML engine on
  first transcribe; reuses it for subsequent calls.
- `Sources/TranscriptionKit/WhisperKitModelManager.swift` — list/download/delete
  variants under `~/Library/Application Support/KosmoNotes/whisperkit/`.
- `App/State/WhisperKitDownloadState.swift` — `@Observable` view-model wired
  into Settings → Transcription with progress bar + per-variant size badge.
- `App/Views/Settings/WhisperKitSection.swift` — UI: model picker, Download /
  Delete buttons, recommended-default hint, downloaded-list with sizes.
- `Package.swift` — adds `argmaxinc/WhisperKit` (resolved 0.18.0) as a
  dependency of the existing `TranscriptionKit` target.
- `RecorderState.start` pre-flights the WhisperKit case: refuses to start if
  no variant picked OR the variant isn't on disk yet, with a message pointing
  at Settings → Transcription.

Stack invariant changes:
- The "Cloud-only transcription. No local Whisper" line is REPLACED by the
  hybrid invariant above.
- `argmaxinc/WhisperKit` joins the `Package.swift` dependency list. It pulls
  `swift-transformers`, `swift-jinja`, `swift-collections`, `yyjson`,
  `swift-asn1`, `swift-crypto`, `swift-argument-parser` transitively.

Default lives where it lived: cloud (whatever provider the user last picked).
WhisperKit is the user-selectable fifth option, NOT the new default — the
download is several hundred MB to a few GB depending on the variant, and we
don't surprise users with that on first launch.

- The complete Rust workspace is preserved on branch `archive/jarvis-studio-rust`. Do not check that branch out unless explicitly asked for historical reference.
- The Jarvis Studio design doc (`docs/plans/2026-05-01-jarvis-studio-design.md`) is retained on `main` for cross-references — sections §3.1 (External Dependency Lifecycle) and §8 (Sharing pipeline) are reused conceptually in Jarvis Note's design.
- The Jarvis Studio implementation plan (was in `.omc/plans/`) is **not** on main — it lives in archive only. Do not reference it for new development.
- The vibe-test report (`docs/plans/2026-05-01-vibe-tests.md`) and Chrome Extension analysis (`docs/plans/2026-05-01-chrome-extension-analysis-uk.md`) are retained for the journey trail but apply to Jarvis Studio, not Jarvis Note.

When the user asks about "the project" or "implementation", they mean **Jarvis Note** unless they explicitly say "Jarvis Studio" or "the archive."

## Stack invariants (load-bearing — do not violate)

These come from §3 of the Jarvis Note design doc.

- **Pure Swift / SwiftUI / AppKit.** No Rust, no FFI, no webview, no Tauri / iced / Electron. Native frameworks only: `AVAudioEngine`, `AVPlayer` / `AVPlayerView`, `URLSession`, `GRDB.swift`, Swift concurrency. Bundle target: 5–15 MB. Single `.app`.
- **Hybrid transcription — cloud default, on-device opt-in.** Cloud providers (OpenAI Whisper / Deepgram / Gemini / OpenRouter) remain the default. As of 2026-05-04, **WhisperKit (Argmax CoreML port of Whisper)** is wired in as an opt-in fifth provider for users who want fully-local, free, private transcription. Models live in `~/Library/Application Support/KosmoNotes/whisperkit/<variant>/` and are downloaded on demand from `argmaxinc/whisperkit-coreml` — never bundled, so the .app stays under the 15 MB target. Privacy posture upgrades from "partial — every recorded second leaves the machine" to "user-selectable; default cloud, opt-in fully local". Ollama still covers the LLM stage only. (See §"Pivot history → 2026-05-04" for rationale.)
- **Filesystem sidecars are source of truth, SQLite is rebuildable index.** Sessions live in `~/Library/Application Support/KosmoNotes/recordings/<sid>/` with `audio.m4a` (AAC; was `audio.opus` in design — see "Encoder deviation"), `transcript.jsonl`, `summary.md`, `actions.json`. Optional: `screen.mp4` when recording mode is Audio + Screen. SQLite (`sessions.sqlite`) backs FTS5 + filtering and must be rebuildable from sidecars.
- **macOS 14.0+ is the actual deployment target.** Package.swift and project.yml both pin `.macOS(.v14)`; LSMinimumSystemVersion mirrors that, so macOS will refuse to launch the binary on <14. The 12.3–13.x "best-effort" fallback described in earlier revisions of the design doc was never implemented (the Recorder, Library, Settings, RecorderState, AudioEngine etc. are all gated behind `@available(macOS 14.0, *)`). The startup `<12.3` modal in `KosmoNotesApp.checkMinimumOS` is dead code preserved for documentation. **If you genuinely need 12.3+ support, lowering the deployment target requires removing every `@available(macOS 14.0, *)` and replacing `@Observable` / `KeyboardShortcuts` 2.x APIs.** Within 14.x: Core Audio Tap is 14.4+, ScreenCaptureKit audio fallback covers 14.0–14.3.
- **Screen recording is optional, configurable, and off by default.** `AppSettings.recordingMode` controls whether screen.mp4 is captured alongside audio. Requires Screen Recording TCC permission when enabled. Screen frames are used locally for vision-chat only — never uploaded.
- **Signed builds, no notarization, no auto-update.** `make install` signs with Apple Development cert (`700E6802C639969593A1AC7F57C1FBFA0A1C7762`, Team `Q7ZGRSDQSQ`) so TCC permissions persist across updates. Not notarized — hand-shared binaries require Gatekeeper bypass: `xattr -d com.apple.quarantine /Applications/KosmoNotes.app`.
- **Secrets in macOS Keychain.** Configuration JSON stores only Keychain account references; never plain-text secrets.
- **Provider abstraction is one protocol.** `Provider` (in §7 of design doc) covers Anthropic / OpenAI / OpenRouter / Ollama. Default LLM: Anthropic Claude Sonnet (latest at ship time). Default transcription: Deepgram Nova-2 with EU residency.
- **Ollama is REST-only.** No bundled inference. User configures their own endpoint. v1 supports `/api/chat` (native), `/v1/chat/completions` (OpenAI-compat), and `/v1/messages` (Anthropic-compat for tool use) — picked at runtime, not compile time.
- **No hosted viewer page for shared links.** Presigned URLs point at the raw audio / markdown bundle. Recipients open in browser.

## Build and run

**First time after cloning** — generate the Xcode project (gitignored):

```sh
xcodegen generate
```

**Primary workflow — build, sign, and install in one step:**

```sh
make install   # release build → codesign → cp to /Applications
make test      # swift test with Xcode toolchain
```

The `Makefile` at repo root handles the full pipeline. `make install` signs the binary with the Apple Development certificate (`700E6802C639969593A1AC7F57C1FBFA0A1C7762`, Team `Q7ZGRSDQSQ`) so TCC permissions (microphone, screen recording, accessibility) persist across updates. **Always use `make install` rather than running xcodebuild manually.**

**Toolchain requirement:** `swift test` (and `make test`) require Xcode's toolchain, not Command Line Tools only. Plain `swift test` without `DEVELOPER_DIR` set will run zero tests. The Makefile sets this automatically, but if running manually:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

375 tests in 78 suites pass in ~60 s. FTS5 perf benchmark is gated behind `JN_RUN_PERF=1`.

**`make test` scope caveat:** `make test` (= `swift test`) only runs the SwiftPM `Tests/`
targets (the kit libraries). It does **not** compile the App target or run `AppTests/` (e.g.
`ChatStateBehaviorTests`) — those depend on the App target and run via the Xcode
`KosmoNotesTests` scheme. Use **`make test-app`** for the App-layer behavior tests, or
**`make test-all`** to run both. (`test-app` disables signing because the app is signed
post-build by `make sign`, not by xcodebuild.)

Other commands:
- `xed .` — open in Xcode
- Distribution: `ditto -c -k --keepParent /Applications/KosmoNotes.app KosmoNotes.zip` → hand-share

**Code signing note:** Builds are signed post-build (not via xcodebuild `CODE_SIGN_IDENTITY`) because SPM package dependencies use `CODE_SIGN_STYLE=Automatic` which conflicts with manual signing flags. The Makefile builds with `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`, then calls `codesign --force --deep` afterward.

**Permission check on startup:** `checkPermissionsOnStartup()` in `KosmoNotesApp.swift` runs on every launch. It uses `CGPreflightScreenCaptureAccess()` (reliable on macOS 15+/26) to check screen recording — shows an alert only when genuinely denied. Microphone access is requested at first record. **Do NOT use `SCShareableContent.excludingDesktopWindows` as a TCC probe** — on macOS 15+/26 it throws `-3801 userDeclined` even when permission IS granted (false positive confirmed).

## Editing the design doc

`docs/plans/2026-05-02-jarvis-note-design.md` is the spec, not a draft. Don't silently change decisions there to match implementation drift — if implementation diverges, that's a discussion, and the design doc gets a new dated revision rather than an in-place edit. The §15 Decision Log is load-bearing: it records what was settled and what would cause revisit.

## Pivot-time discipline

The Jarvis Studio → Jarvis Note pivot happened after three stack pivots in three days (Tauri → iced → Swift) and four review rounds. **The Swift / cloud-transcription decisions are settled.** A Rust core or webview frontend is **out of scope** for v1 and would invalidate the entire spec.

Screen recording was originally deferred but was reinstated on 2026-05-02 evening (see "Pivot history" above) — it is now an opt-in feature, not a product direction change. If the user proposes another pivot, surface it as a major decision needing a separate design pass — don't quietly accommodate.

## Editing this file

If `docs/plans/2026-05-02-jarvis-note-design.md` is the spec, this file is the operating manual for working in the repo. Update it when the stack invariants change, when new sections are added to the design doc, or when a recurring user instruction emerges. Don't pad it with code-style preferences (those go in repo-level config like `.swiftlint.yml`) or feature wishlists (those go in the design doc's open-questions section).
