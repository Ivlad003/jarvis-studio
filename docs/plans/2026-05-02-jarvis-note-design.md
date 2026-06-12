# Jarvis Note — Voice-First AI Capture for macOS

**Date:** 2026-05-02
**Status:** Draft (post-Jarvis-Studio pivot) · **v1.0 scope-reduced 2026-05-02 after Critic round-2** (see §15 D12) · **Revision 2026-06-12: live transcription + live chat with tools accepted for v1.x; speaker echo cancellation added** (see §15 D17–D21)
**Author:** ivlad003@gmail.com
**Working title:** Jarvis Note (final name TBD — see §16)
**Reference:** This document supersedes `docs/plans/2026-05-01-jarvis-studio-design.md` for new development. Jarvis Studio's recording-pipeline learnings (audio fragmentation, atomic writes, External Dependency Lifecycle pattern) carry forward; the implementation stack does not.

> **v1.0 scope reduction (post-Critic round-2):** Per-process Core Audio Tap, Voice Note Mode, and S3 Sharing are **deferred to v1.1**. v1.0 ships ScreenCaptureKit-mixdown audio for all macOS 12.3+, Meeting + Dictation modes only, Save-dialog export only. See §15 D12. The implementation plan at `.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` is canonical for what actually ships in v1.0; this design doc describes the broader v1 vision.

---

## 1. Context & Motivation

### What changed since 2026-05-01

The original Jarvis Studio — iced-based desktop screen recorder with `scap` capture, ffmpeg sidecar, multi-pipeline orchestration, AI annotations, agent Q&A backends, S3 sharing — landed v0.1.1 on disk: 37 passing tests, working audio-only recording, Whisper Cloud transcription, three-tab UI. It also surfaced four hard truths during the four-week build:

1. **The screen-recorder use case is over-served.** Loom, Cap, Cleanshot X, Granola, OBS, QuickTime all do the recording job. The differentiation surface — AI annotations, agent Q&A, self-hosted sharing — was real but spread thin across surfaces.
2. **scap is fragile.** Pinning at 0.0.8 with a "FFmpeg-direct fallback designed in" was honest about the risk. It paid the rent but the maintenance cost is non-trivial for a single-developer hobby.
3. **TCC is a UX cliff for non-notarized apps.** Every Record click on a fresh install hit "Permission to capture the screen is not granted" with no easy escape. The "open System Settings automatically" mitigation works, but the user has to Cmd+Q the host process and relaunch — friction every time.
4. **The actual workflow demand is voice, not screen.** The recording sessions a senior engineer working with Western European clients actually generates are: client calls, dictation into Cursor, voice memos that become tasks. Screen recording is a supporting cast member, not the lead.

### What this product is

A **macOS menu-bar app** that captures audio (mic + system audio), transcribes it via cloud APIs, and runs AI processing — summaries, action items, voice-to-text dictation, searchable archive with audio playback and sharing. Native, hotkey-driven, low-overhead. Personal-use; shared by binary handover, not by App Store.

Closest analogs: **Granola** (meeting notes), **Wispr Flow** (dictation), **Otter** (transcript archive), **Fathom** (Zoom-bot meeting summary).

### Honest competitor landscape

| Tool | What it does well | Where Jarvis Note differs |
|---|---|---|
| **Granola** | macOS-native, polished menu-bar UX, automatic Meet/Zoom detection, opinionated AI summary templates | Granola supports French — quantifying "better at UA/RU" honestly: Granola transcribes UA/RU through Deepgram/AssemblyAI, same providers we'd use. The actual edge is **summary-language flexibility** (record UA → output FR/EN summary), not transcription accuracy. The needle moves on UX shape, not raw accuracy. |
| **Wispr Flow** | Dictation latency, system-wide push-to-talk, on-device Whisper-tiny | Cloud-first dictation accepts a worse latency floor (~1.0–1.5s end-to-end vs Wispr's <0.5s). Trade-off: better multi-language, no Whisper-tiny-on-Apple-Silicon engineering. |
| **Otter** | Long-form meeting archive, web app, mobile, team features | Otter is web-first; we're macOS-first, single-user, no team. Different product. |
| **Fathom** | Zoom bot joins call, transcribes server-side, automatic summary | Bot joins meetings (visible to participants), Zoom-only. We capture system audio locally — invisible to participants, works on any platform (Meet, Zoom, FaceTime, Teams, Discord). |

### Real differentiation

1. **UA / RU / EN / FR native** — record UA-language client call, get FR summary delivered to a French client. Transcription quality on UA/RU is at-parity with competitors (same providers); the edge is the **summarization-language pivot** and the UI never assuming the operator and the audience share a language.
2. **Self-hosted LLM via Ollama REST** — bring-your-own GPU box (Hetzner, etc.). LLM stage is local even when transcription isn't. Privacy claim is partial (see §12) but real for the LLM half.
3. **Developer-context paste** — Cursor / VS Code / GitHub / Linear / Jira aware. Markdown in editors, plain text in chat, code-aware in IDEs.
4. **No bots in meetings** — system audio capture, never a "Jarvis Note has joined the meeting" notification.

### Why this pivot ships

The deferred-and-resurrected Jarvis Studio was 24 days of plan, ~5 weeks of build. This product is smaller: no scap, no ffmpeg sidecar, no iced multi-tab editor, no agent subprocess plug-ins, no annotation pipeline. Pure Swift / SwiftUI / AppKit, native frameworks, single binary, ~5–15 MB. Realistic v1 ship: 4–6 weeks for one engineer (see §14 risk register on the honest probability).

---

## 2. Goals & Non-Goals

### v1 goals

- Three capture modes (Meeting / Dictation / Voice Note) with clear triggers and hotkey-driven activation
- Audio capture: mic + system audio, macOS 14.4+ via Core Audio Tap, 12.3–14.3 fallback, <12.3 explicitly unsupported
- Cloud transcription: streaming where supported (Deepgram, AssemblyAI), batch fallback (Whisper). Multi-language detection. Diarization where available.
- AI processing: Anthropic / OpenAI / OpenRouter / Ollama via a single `Provider` protocol. Default: Anthropic Claude Sonnet (latest at ship time)
- Library window with native AVPlayer + variable-speed playback + click-to-jump from transcript + FTS5 search
- Sharing via S3-compatible upload (RustFS / MinIO / R2 / B2) with presigned URLs; export formats: Markdown, plain text, audio, audio+transcript zip
- Single binary distribution. No installer, no auto-update. Manual `.app` replacement.

### Deferred (will likely build)

- ~~Screen recording (deferred, month 6+)~~ → **Screen recording reinstated 2026-05-02 evening** (D14); see CLAUDE.md "Pivot reversals" and `Sources/CaptureKit/ScreenRecorder.swift`. Implemented as an opt-in recording mode (Audio only / Audio + Screen) with SCStream → AVAssetWriter H.264+AAC screen.mp4 sidecar and vision-capable chat frame extraction.
- Embedding-based semantic search across transcripts (post-FTS5 — needs a stable embedding provider choice; see §16)
- Per-user shared S3 bucket with per-recipient ACLs (v1 just trusts presigned URL secrecy)
- iOS companion app (syncs sessions, plays back, can't capture system audio per Apple TCC)
- Linux port — not while macOS-specific Core Audio Tap / Accessibility / AVPlayer are load-bearing
- Real-time live captions during a Meeting Mode call (engineering risk, latency floor)

### Rejected (will not build)

- **Local transcription** (Whisper / WhisperKit / on-device CoreML model). Quality on UA/RU/multi-language is materially worse than cloud at the model sizes that fit in 15 MB binary; the engineering cost is a project unto itself. The privacy posture is honestly stated in §12.
- **Bundled local LLM** (llama.cpp / MLX / Ollama-embedded). Same reasoning: Ollama-via-REST gives the user the local-LLM option with their own hardware sizing; bundling models in our binary defeats both binary size and "user controls their own inference" goals.
- **CLI agent subprocess** (Claude Code / Codex / aider). Was a Jarvis Studio §7 surface; doesn't fit a voice-first product. The chat is in the LLM stage; the action loop is the user pasting transcript into their existing Cursor/Claude.ai session.
- **Webcam / PiP** — voice product, no video.
- **Code signing, notarization, Sparkle, App Store** — single-user / hand-shared binary, hand the cost.
- **Auto-update** — replaced by manual `.app` replacement. Honest constraint of the no-signing decision.
- **Multi-user / team workspaces** — single-user app. Sharing is one-way (export to a recipient), not collaborative.
- **Telemetry, analytics, auth, payments, pricing tiers** — personal tool, not a product to sell.

---

## 3. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Jarvis Note — single .app, ~10 MB target                            │
│                                                                      │
│  ┌────────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│  │  MenuBarExtra      │  │  Library window  │  │  Settings window │ │
│  │  (popover)         │  │  (NSWindow)      │  │  (NSWindow)      │ │
│  │  • mode picker     │  │  • session list  │  │  • Providers     │ │
│  │  • record button   │  │  • AVPlayer      │  │  • Ollama        │ │
│  │  • mic level       │  │  • transcript    │  │  • Hotkeys       │ │
│  │  • last session    │  │  • search/filter │  │  • Privacy       │ │
│  └─────────┬──────────┘  └────────┬─────────┘  └─────────┬────────┘ │
│            │                       │                       │         │
│            └────────────┬──────────┴───────────────────────┘         │
│                         │ all SwiftUI views observe                  │
│                         ▼                                            │
│              ┌──────────────────────────┐                            │
│              │  AppState (@MainActor    │                            │
│              │   @Observable)           │                            │
│              └────────────┬─────────────┘                            │
│                           │                                          │
│   ┌───────────────────────┼───────────────────────────┐              │
│   ▼                       ▼                           ▼              │
│ ┌─────────────┐  ┌────────────────────┐   ┌──────────────────────┐ │
│ │ CaptureKit  │  │ TranscriptionKit   │   │  AIProcessingKit     │ │
│ │             │  │                    │   │                      │ │
│ │ AVAudioEngine│  │ Provider protocol │   │ Provider protocol    │ │
│ │ Core Audio  │  │ • Whisper (OpenAI) │   │ • Anthropic          │ │
│ │   Tap       │  │ • Deepgram        │   │ • OpenAI             │ │
│ │ SCKit (fbk) │  │ • AssemblyAI      │   │ • OpenRouter         │ │
│ │             │  │ URLSession        │   │ • Ollama (REST)      │ │
│ │ Writes:     │  │ Streaming + batch │   │ URLSession + SSE     │ │
│ │  audio.opus │  │                    │   │                      │ │
│ │  (chunked,  │  │ Writes:            │   │ Writes:              │ │
│ │  on disk)   │  │  transcript.jsonl  │   │  summary.md          │ │
│ │             │  │  + transcript.txt  │   │  actions.json        │ │
│ └──────┬──────┘  └─────────┬──────────┘   └──────────┬───────────┘ │
│        │                   │                         │             │
│        └───────────────────┼─────────────────────────┘             │
│                            ▼                                        │
│              ┌─────────────────────────┐                            │
│              │  Storage (GRDB.swift)   │                            │
│              │  + filesystem sidecars  │                            │
│              │                         │                            │
│              │ ~/Library/Application   │                            │
│              │  Support/KosmoNotes/    │                            │
│              │   sessions.sqlite       │                            │
│              │   recordings/<sid>/     │                            │
│              │     audio.opus          │                            │
│              │     transcript.jsonl    │                            │
│              │     summary.md          │                            │
│              │     actions.json        │                            │
│              └─────────────────────────┘                            │
│                                                                      │
│  Sidecar processes: NONE. Bundled binaries: NONE.                   │
│  External calls: HTTPS to user-configured providers.                │
└──────────────────────────────────────────────────────────────────────┘
```

### Three core principles

1. **Pure Swift, no FFI.** No Rust, no C++, no webview, no Tauri / iced / Electron. Native frameworks: `AVAudioEngine`, `AVPlayer` / `AVPlayerView`, `URLSession`, `GRDB.swift`, Swift concurrency. Bundle 5–15 MB. Single `.app`.
2. **Filesystem sidecars are source of truth, SQLite is index.** A user can `rm sessions.sqlite`, the app rebuilds it on next launch by walking `recordings/`. Transcripts and summaries live in the session folder as `transcript.jsonl`, `summary.md`, `actions.json`. SQLite is for FTS5, sort, filter, aggregations — never authoritative.
3. **Cloud is the default; Ollama is for the LLM stage only.** Transcription is always cloud (rejected in §2). LLM stage routes to user-chosen provider; Ollama is one option, not a special-cased local engine.

### What's deliberately not in this diagram

- **No daemon, no XPC service, no agent.** Single process. macOS sandbox accepted (the app is non-sandboxed by default since unsigned).
- **No web server.** No `localhost:N` port. Avoids macOS firewall prompts (a Jarvis Studio §5 trap).
- **No FFI boundary.** Everything is Swift. The cost is reimplementing a few primitives (audio fragmentation, segment integrity) but it's small.

### Implementation note: app shell (shipped 2026-05-03)

The diagram above shows `MenuBarExtra`. **What shipped uses `NSStatusItem` + `NSMenu`** (`App/KosmoNotesApp.swift`). Reason: `MenuBarExtra` is unreliable under `LSUIElement` apps that wake from sleep — the SwiftUI scene gets torn down and re-created on wake, which intermittently loses the status-item icon and dismisses any open popover. `NSStatusItem` is the AppKit-level primitive `MenuBarExtra` wraps, and managing it directly avoids the wake-from-sleep race. Functionally identical surface (icon, popover, mode picker, record button, mic level); architecturally one layer lower.

---

## 4. Capture Modes

Three modes. Each has a different latency budget, a different post-processing pipeline, and a different UI contract.

| Mode | Duration | Audio | Latency budget (Stop → output) | Post-process |
|---|---|---|---|---|
| Meeting | 30 min – 3 hr | Mic + system | 1–5 min for summary; transcript streams during call | Diarized transcript + structured summary + action items |
| Dictation | < 60 s | Mic only | **< 1.5 s end-to-end** (Stop → text in active app) | Optional one-shot LLM cleanup; AX paste into focused field |
| Voice Note | 1–15 min | Mic only | 10–30 s | Transcript + concise note (one of: task / journal / checklist / freeform) |

### Mode triggers

| Trigger | Effect |
|---|---|
| Click MenuBarExtra → mode picker | Manual entry; current mode highlighted |
| `Cmd+Shift+R` | Toggle Meeting Mode |
| `Cmd+Shift+D` (push-to-talk) | Hold-to-record Dictation Mode; release pastes |
| `Cmd+Shift+D` (toggle, configurable) | Press to start, press to stop |
| `Cmd+Shift+N` | Toggle Voice Note Mode |
| Meet/Zoom auto-detect (when enabled) | Suggest Meeting Mode via menu-bar nudge: "Detected Zoom call — start Meeting recording? [Yes][Dismiss]" |

Meet/Zoom detection: poll `NSWorkspace.shared.runningApplications` for bundle IDs `com.tinyspeck.slackmacgap`, `us.zoom.xos`, `com.microsoft.teams2`, `com.google.Chrome` + `com.apple.Safari` + window title heuristic for `meet.google.com` / `*.zoom.us`. Polling at 2 Hz when the app is foregrounded; 0.2 Hz idle. Suggestion is non-modal — never auto-starts recording without user confirm.

### Mode state machine

```
        ┌───────────────────────────────────────────────────────┐
        │                                                       │
        ▼                                                       │
   ┌─────────┐  hotkey/click   ┌──────────┐  audio data   ┌─────┴──────┐
   │  Idle   │────────────────▶│ Starting │──────────────▶│ Recording  │
   └─────────┘                 └──────────┘               └──────┬─────┘
        ▲                                                        │
        │                                                hotkey/click │ pause (Meeting only)
        │                                                        ▼
        │                          ┌──────────┐               ┌────────┐
        │                          │ Stopped  │◀──────────────┤ Paused │
        │                          └────┬─────┘   resume      └────────┘
        │   AI processing complete      │
        └───────────────────────────────┘
                                        │
                                        ▼
                              ┌────────────────────┐
                              │ Processing         │
                              │  (transcribe + AI) │
                              └────────┬───────────┘
                                       │
                                       ▼
                              ┌────────────────────┐
                              │  Complete          │
                              │  (in Library)      │
                              └────────────────────┘
```

Pause/resume is **Meeting only**. Dictation has no pause (it's <60s). Voice Note has no pause (interrupting it triggers Stop+Process).

### Sticky last-used vs. context detection

The mode picker remembers the last-used mode but **does not auto-select** based on Meet/Zoom detection. The detection event raises a non-modal suggestion that the user can accept or dismiss. Auto-mode-switching at recording-start time would be confusing; users will tolerate one extra click for explicit consent.

### Chunked-upload differences per mode

| Mode | Upload strategy |
|---|---|
| Meeting | Stream 5-second Opus chunks to transcription provider as they're written. Chunks live on disk in `recordings/<sid>/segments/<n>.opus` until Stop, then `ffmpeg`-equivalent (AVAssetWriter) concatenates into `audio.opus`. Stream-Stop hand-off finalizes the in-flight transcript. |
| Dictation | Hold buffer in memory until Stop (max 60 s = ~120 KB Opus); single POST upload. No chunking — minimizes round-trips. |
| Voice Note | 10-second chunks, batch upload at Stop. Streaming would shave 30s off output but Voice Note's 10–30 s budget allows the simpler batch path. |

---

## 5. Audio Pipeline

```
┌──────────────────────┐                ┌────────────────────────┐
│   AVAudioEngine      │  16-bit float  │  Mixer (in-process)    │
│   ┌─────────────┐    │   48 kHz mono  │                        │
│   │ Mic input   │───▶│                │  • Resample to 16k     │
│   └─────────────┘    │                │    mono for upload     │
│                      │                │  • Maintain 48k        │
│   ┌──────────────────┐                │    stereo for archive  │
│   │ Core Audio Tap   │                │  • Apply soft gate     │
│   │ (system audio,   │───────────────▶│  • Mix mic+sys with    │
│   │  per-process)    │                │    metadata-tagged     │
│   └──────────────────┘                │    channels (1=mic,    │
│   macOS 14.4+                         │    2=sys)              │
│                                       └────────────┬───────────┘
│   Fallback (12.3–14.3):                            │
│   ┌────────────────────────┐                       │
│   │ ScreenCaptureKit audio │                       │
│   │ (system mixdown)       │                       │
│   └────────────────────────┘                       │
│                                                    ▼
│                                       ┌────────────────────────┐
│                                       │  Opus encoder (Apple   │
│                                       │   AudioConverter)      │
│                                       │  ~32 kbps mono for     │
│                                       │  cloud upload, 96 kbps │
│                                       │  for archive           │
│                                       └────────────┬───────────┘
│                                                    │
│                                                    ▼
│                              recordings/<sid>/segments/<n>.opus
└──────────────────────┘
```

### Defaults

| Setting | Default | Rationale |
|---|---|---|
| Mic sample rate | 48 kHz mono float32 | AVAudioEngine native; one downsample to 16 kHz for upload |
| System audio | Per-process Tap on 14.4+, mixdown on 12.3–14.3 | Per-process gives isolation from user's Spotify; mixdown is lossy but workable |
| Encoding at rest | Opus 96 kbps mono | ~700 KB/min; 60 min = 42 MB |
| Encoding for upload | Opus 32 kbps mono | ~250 KB/min for transcription provider; well below provider per-request limits |
| Segment duration | 5 s for Meeting, full clip for Dictation, 10 s for Voice Note | Streaming vs batch trade-off (§4) |
| Disk-buffer headroom | 200 MB free on `~/Library/Application Support` partition | Surface a recorder warning at <200 MB; refuse to start at <50 MB |

### macOS version degradation

| macOS version | Capture path | Limitations |
|---|---|---|
| 14.4+ | Core Audio Tap (per-process) + AVAudioEngine | Full-fidelity. Can isolate target processes. |
| 12.3 – 14.3 | ScreenCaptureKit `audio` content + AVAudioEngine | Whole-system mixdown — captures ALL system audio (notifications, Spotify, etc.); user must mute non-meeting sources |
| < 12.3 | **Unsupported** | Block at startup with clear modal: "macOS 12.3 required for system audio. Mic-only mode available — continue?" |

### Buffer sizing & backpressure

- AVAudioEngine input tap buffer: **0.1 s frames** (4800 samples @ 48 kHz). Lower buffer = lower latency (matters for Dictation), higher = lower CPU. 0.1 s is the sweet spot per WWDC guidance.
- Encoder ring buffer: **1 s** (~10 frames). On overflow, **drop oldest frame and increment `framesDropped` counter** — surface in UI. Recording is sacred; in practice an Opus encoder on M-series doesn't overflow.
- Upload queue: **disk-backed**. Each finalized Opus segment is appended to a queue file (`recordings/<sid>/upload-queue.jsonl`) before the network task is scheduled. If the network is down or the process is killed, the queue resumes on next launch. **Never drop a recorded second to a network problem** (per design-doc invariant carried from Jarvis Studio §3.1).

### Crash-safe writing

Adapted from Jarvis Studio §4 fragmented-MP4 trick, simplified for audio-only:

- Each Opus segment is written via `AVAssetWriter` with `shouldOptimizeForNetworkUse = true` (Opus is naturally segment-resilient — no global moov needed).
- Segment file is opened, written, **fsync'd, then closed** before the next segment starts. A SIGKILL or power loss costs ≤ 5 s of audio (one in-flight segment).
- On launch, `recordings/<sid>/` is scanned for `segments/*.opus` files where `<sid>` has no `session.json` `status: "complete"`. The user is offered a **Recover** action that concatenates surviving segments and finalizes the session metadata.
- `session.json` is written via `tmp + fsync + rename` (carried-forward atomic-write invariant).

### Format choice (provider-dependent on upload)

- **At rest:** Opus 96 kbps. Universally decodable on macOS via `AVPlayer`. ~700 KB/min.
- **For Whisper API:** Opus is supported as of late 2024; no transcode.
- **For Deepgram:** Opus accepted natively; preferred encoding.
- **For AssemblyAI:** Re-encode to Opus 16 kHz mono on upload (their preferred input). One-pass via AudioConverter; no quality loss vs. our 16k mono internal stream.

WAV at rest is rejected: 60 min × 48 kHz × 16-bit mono ≈ 330 MB. Opus 96 kbps is 42 MB for the same content with no perceptible quality loss for speech.

---

## 6. Transcription Pipeline (cloud-only)

### Provider matrix

| Provider | Streaming | UA quality | RU quality | FR quality | Diarization | EU residency | Latency (typical) | Pricing (per minute) |
|---|---|---|---|---|---|---|---|---|
| **OpenAI Whisper** (`whisper-1`) | No (batch only) | Good | Very good | Good | No (must run pyannote separately) | US-only | 0.5–1.5× realtime batch | $0.006 |
| **Deepgram** (`nova-2`) | Yes | Very good | Excellent | Very good | Yes (built-in) | Yes (EU region) | Streaming: ~300 ms; batch: 0.1× realtime | $0.0043 |
| **AssemblyAI** (`best`) | Yes (real-time) | Good | Good | Very good | Yes (built-in) | No (US-only) | Streaming: ~500 ms; batch: ~0.05× realtime | $0.0065 |

### Recommended default

**Deepgram Nova-2.** Reasoning:
- Streaming gives Meeting Mode useful live-caption surface even though we don't ship live captions in v1.
- UA/RU quality is the best of the three (Nova-2 was retrained on Slavic-language augmented data in late 2024).
- Built-in diarization removes the pyannote-on-our-side burden.
- EU residency option is a real privacy half-step (still cloud, but at least not crossing the Atlantic for a French client's call).
- Cheapest of the three.

The user can override per-session or globally via Settings → Transcription. Whisper is the fallback for languages where Deepgram has weaker support (Polish, Czech, Hungarian — outside our v1 must-have but easy to grant).

### Streaming protocol (Deepgram example)

```
Meeting Mode
  ┌──────────────────────────────┐    WebSocket    ┌──────────────────────┐
  │ Mic + system Opus chunks     │────────────────▶│ Deepgram /v1/listen  │
  │ (5-second windows)           │                 │ ?model=nova-2&       │
  └──────────────────────────────┘                 │  smart_format=true&  │
                                                   │  diarize=true&       │
                                                   │  language=multi      │
                                                   └──────────┬───────────┘
                                                              │ JSON events
                                                              ▼
                                              ┌────────────────────────────┐
                                              │ TranscriptionStream actor  │
                                              │  • partial events → UI    │
                                              │  • final events →          │
                                              │     transcript.jsonl       │
                                              │  • UtteranceEnd flushes    │
                                              │     to FTS5 index          │
                                              └────────────────────────────┘
```

### Reconnection

WebSocket dies → reconnect with exponential backoff (250 ms, 500 ms, 1 s, 2 s, 4 s, 8 s; cap 8 s, infinite retries while the recording is active). On reconnect, **resume audio from the in-memory ring buffer** (last 5 s) so the gap is bounded. The user-visible state is a `degraded` pill in the menu-bar — they don't see network blips unless the outage exceeds ~10 s.

### Backpressure

Per §5: disk-queue. If the transcription provider is unreachable, the Opus segments accumulate on disk; the queue drains when connectivity returns. The recording **never blocks on the network**.

### Diarization

- **Deepgram & AssemblyAI:** built-in. Speaker labels arrive in the JSON events.
- **Whisper:** no built-in diarization. v1 doesn't run pyannote locally (rejected in §2 — too much engineering). Whisper-recorded sessions are **single-speaker** in the UI; the user can manually edit speaker labels in Library if needed.

### Multi-language detection

Deepgram supports `language=multi` (auto-detect across UA/RU/EN/FR + 30 others). AssemblyAI requires explicit language hints. Whisper auto-detects from audio. **Default to `multi` on Deepgram**, with a manual override per session in Settings.

For multi-speaker UA-only calls where Deepgram occasionally trips on EN code-switching: ship a per-session **"Lock to Ukrainian"** toggle that forces `language=uk`. Same for `ru`, `en`, `fr`.

### Privacy posture (stated honestly)

**Every recorded second leaves the machine.** Transcription is always cloud. The privacy claim of this app is partial: Ollama covers the LLM stage; the audio still travels to Deepgram / OpenAI / AssemblyAI. EU residency on Deepgram is a partial mitigation. Users who require full local-only audio processing are not the target audience for v1 — direct them to OpenAI Whisper running locally + a self-hosted summary service, which is a different product.

This is documented in §12 and surfaced in the Settings → Privacy panel ("Transcription is always cloud — see provider's data-retention terms").

---

## 7. AI Processing Pipeline

User flow: Stop → audio uploaded to transcription → transcript arrives → transcript + per-mode prompt sent to chosen LLM provider → streamed response → `summary.md`, `actions.json` written.

### Provider abstraction

```swift
protocol Provider: Sendable {
    var capabilities: ProviderCapabilities { get }

    func chat(
        messages: [ChatMessage],
        tools: [Tool]?,
        responseFormat: ResponseFormat
    ) -> AsyncThrowingStream<ChatChunk, Error>
}

struct ProviderCapabilities {
    let maxContextTokens: Int       // Anthropic: 200k; Ollama varies
    let supportsStreaming: Bool     // all four: yes
    let supportsToolUse: Bool       // Anthropic, OpenAI, OpenRouter, larger Ollama: yes; small Ollama: no
    let supportsPromptCache: Bool   // Anthropic only (huge cost win on repeated transcripts)
    let pricing: Pricing?           // nil = local (Ollama)
    let coordSystem: Never          // no vision in v1
}
```

Implementations: `AnthropicProvider`, `OpenAIProvider`, `OpenRouterProvider`, `OllamaProvider`. Each is ~150 lines of `URLSession` + JSON parsing. No SDK dependency; the API surfaces are stable enough that hand-rolling is shorter than wrangling a third-party crate.

Default: **Anthropic Claude Sonnet** (latest at ship time). Falls back to user's chosen provider on Settings change. Per-session override available in the Library row's `…` menu ("Re-process with…").

### Ollama (dedicated subsection)

This is the differentiator and the largest source of v1 footguns.

#### Endpoint config UX

Settings → Ollama:

```
┌───────────────────────────────────────────────────────────┐
│ Ollama                                                    │
├───────────────────────────────────────────────────────────┤
│  Endpoint URL:  [ http://hetzner.local:11434       ]      │
│                                                           │
│  Bearer token:  [ ●●●●●●●●  ] (optional)  [👁 reveal]    │
│                                                           │
│  Default model: [ qwen2.5:14b                  ▾ ]        │
│                 ↳ Populated from GET /api/tags           │
│                                                           │
│  API mode:      ( ) OpenAI-compatible (/v1/chat/...)      │
│                 (•) Native Ollama   (/api/chat)           │
│                                                           │
│              [ Test connection ]   Status: ● ready        │
└───────────────────────────────────────────────────────────┘
```

#### Discovery

`GET <endpoint>/api/tags` → JSON array of `{name, size, modified_at, digest}`. Populates the Default Model picker. Picker is **disabled until Test connection passes** (keeps a clean state machine — see §11).

#### OpenAI-compat vs. native

| | OpenAI-compat (`POST /v1/chat/completions`) | Native (`POST /api/chat`) |
|---|---|---|
| Streaming format | SSE `data: {...}\n\n` | NDJSON: `{"message": {...}, "done": false}\n` |
| Tool-use shape | OpenAI's `tool_calls` array | Ollama's `message.tool_calls` (similar but different keys) |
| Compatibility | Works against Together, Groq, Fireworks, etc. | Ollama-specific; future feature drift may break |
| Streaming reliability | OpenAI-format SSE has a wider testing surface | Ollama's NDJSON is simpler to parse but less broadly supported |

**Default: native `/api/chat`.** Reasoning: it's the canonical Ollama API, less likely to drift than the OpenAI-compat shim. The user can flip to OpenAI-compat in Settings if they're using Together/Groq/Fireworks (an open question for v1, see §16). The implementation supports both — switching is a runtime decision, not a recompile.

#### Self-hosted failure modes

| Failure | Detection | UX |
|---|---|---|
| DNS unresolved | `URLSession` returns `cannotFindHost` | Banner: "Ollama endpoint unreachable. Check the URL in Settings." State → `unavailable`. |
| TLS handshake failure (self-signed cert) | `URLSession` returns `serverTrustEvaluationFailed` | Banner: "TLS error. If using a self-signed cert, you may need to trust it manually in Keychain Access. [Show docs]" |
| Server returns 503 | HTTP status | State → `degraded`. Retry once after 5 s, then surface error. |
| Model not pulled (`POST /api/chat` returns 404 with body `{"error":"model 'qwen2.5:14b' not found"}`) | Parse body | Modal: "Model `qwen2.5:14b` is not pulled on the Ollama server. [Pull on server (~9 GB)] [Switch model]". The Pull button POSTs `/api/pull` and surfaces a progress bar; the user must stay in Settings until it completes (or cancel). |
| Server OOM (504, or stream truncates) | Status code or short response | "The Ollama server appears overloaded. Try a smaller model in Settings → Ollama." |
| Bearer token rejected (401) | HTTP status | Banner with "Invalid bearer token. Update in Settings → Ollama." Highlight the token field. |

#### Streaming response format

`POST /api/chat` with `"stream": true` returns NDJSON:

```
{"model":"qwen2.5:14b","created_at":"2026-05-02T10:00:00Z","message":{"role":"assistant","content":"The"},"done":false}
{"model":"qwen2.5:14b","created_at":"2026-05-02T10:00:00Z","message":{"role":"assistant","content":" call"},"done":false}
{"model":"qwen2.5:14b","created_at":"2026-05-02T10:00:00Z","message":{"role":"assistant","content":" was"},"done":false}
...
{"model":"qwen2.5:14b","created_at":"2026-05-02T10:00:01Z","message":{"role":"assistant","content":""},"done":true,"total_duration":...,"prompt_eval_count":2048,"eval_count":312}
```

Parsing: `URLSession.bytes(for:)` → `AsyncSequence<UInt8>` → split on `\n` → `JSONDecoder().decode(OllamaChunk.self, from: line)` → emit `.delta(content)` events to the UI; on `done: true` emit `.complete(usage:)`.

### Prompt templates per mode

| Mode | System prompt outline |
|---|---|
| Meeting | "You are summarizing a {target_language} business call between {participant_count} speakers. Produce: (1) one-paragraph executive summary, (2) bulleted action items with owner and due date when stated, (3) decisions made, (4) outstanding questions. Source language: {source_language}. Target summary language: {target_language}. If source ≠ target, translate; preserve proper nouns and quoted phrases." |
| Voice Note | "Structure this voice note. Detect type (task / journal / checklist / freeform reflection) and format accordingly. Preserve voice; don't summarize away nuance." |
| Dictation | "Clean up this dictation for paste into a {app_context}. Fix punctuation and capitalization. {context_specific_rules}. Do NOT add content; do not summarize. Preserve every spoken word's intent." |

`{app_context}` and `{context_specific_rules}` are derived per §8.

### Cost estimation

For cloud LLM providers, cost is computed pre-send: input_tokens (transcript length / ~3.5) + output_tokens_estimate (mode-specific: Meeting ~600 tokens, Voice Note ~150, Dictation ~50). Multiplied by the provider's pricing card. Surface estimate in a one-line tooltip on the Stop button: "Estimated AI cost: $0.04". Above $1 per session triggers a confirmation modal ("This is a long session. Estimated cost: $1.50. Continue?"). **Ollama is exempt** — local inference is free; cost line is hidden.

---

## 8. Voice-to-Text Dictation

The hottest-iteration mode. <1.5 s end-to-end is the lock-in spec; everything else flexes around it.

### Latency budget

```
User releases hotkey            t = 0
        │
        ▼
Capture stop + Opus encode      ~50 ms
        │  (in-memory, max 60 s of audio = ~120 KB)
        ▼
Upload to transcription         ~150–400 ms
        │  (POST + body upload over typical home connection)
        ▼
Transcription server processing ~200–600 ms
        │  (Deepgram batch on a 30 s clip; longer clips scale linearly)
        ▼
Optional LLM cleanup            +300–800 ms
        │  (Anthropic Sonnet streaming; cleaned output starts arriving in ~300 ms)
        ▼
AX paste into focused field     ~10 ms
        │
        ▼
TOTAL: 710 ms – 1860 ms
```

The 1.5 s target is hit in the median case; outliers (slow network, long dictation, heavy LLM cleanup) trip it. Acceptance: median < 1.5 s, p95 < 2.5 s. **Document the trade-off honestly:** Wispr Flow's <0.5 s comes from on-device Whisper-tiny; we accept ~3–4× the floor in exchange for better multi-language and zero on-device model engineering.

### Where Ollama fits — or doesn't

**Ollama is a poor fit for Dictation cleanup** unless the user has a beefy local box:

- Cloud Anthropic / OpenAI: first token in ~200–400 ms. Cleaned dictation is short — a one-shot ~50-token response — so even at 100 t/s the LLM stage is 500–800 ms.
- Ollama on a remote Hetzner GPU: similar (well-provisioned).
- Ollama on a local M1 MacBook: first token in 1–3 s for a 14 B model. Adds 1.5 s to a budget that was 1.5 s. **Unusable for Dictation.**

**Default behavior:** Dictation Mode forces a cloud LLM provider (Anthropic / OpenAI / OpenRouter) for the cleanup stage **even when the user's global default is Ollama**. Settings → Dictation has an explicit override: "Use my Ollama for Dictation cleanup (warning: latency may exceed 2 s)." Honest, default-on speed.

If the user disables LLM cleanup entirely (Settings: "Paste raw transcription"), the LLM stage is skipped; total budget drops to ~600–1000 ms.

### Push-to-talk vs. toggle

```
Push-to-talk (default): hold Cmd+Shift+D
  • Press → AVAudioEngine starts
  • Release → stop, send to pipeline
  • If held > 60 s, force-stop and surface "Maximum dictation length is 60 s"

Toggle (configurable): tap Cmd+Shift+D
  • First tap → start
  • Second tap → stop and process
  • Auto-stop after 60 s
```

PTT is the default because it matches Wispr Flow's UX and avoids the "I forgot it was recording" failure mode. Toggle is for users with mobility constraints.

### Accessibility API paste

```swift
// 1. Cleaned text arrives from LLM stream → final string.
// 2. Get the focused element via NSAccessibility.
let app = NSWorkspace.shared.frontmostApplication
guard let pid = app?.processIdentifier else { return }
let axApp = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
let element = focused as! AXUIElement
// 3. Insert at the current selection.
AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
```

Two failure modes:
1. **App is sandboxed and rejects AX writes** (Slack desktop, some Electron apps). Fallback: copy to clipboard + simulate Cmd+V via `CGEventCreateKeyboardEvent`. Slower but universal.
2. **No focused field** (e.g., Finder is frontmost). Fallback: copy to clipboard, surface a non-modal banner "Pasted to clipboard — no focused text field detected."

Surface the result in the menu-bar transient toast: "Pasted into Cursor" / "Copied to clipboard."

### App-aware formatting

Detected via `app.bundleIdentifier`:

| Bundle ID prefix | Context | LLM cleanup rules |
|---|---|---|
| `com.todesktop.230313*` | Cursor | Code-aware: preserve indentation, prefer markdown code fences for snippets, never auto-translate code-language tokens |
| `com.microsoft.VSCode` | VS Code | Same as Cursor |
| `com.tinyspeck.slackmacgap` | Slack | Plain text. Strip markdown. Newlines preserved. |
| `com.hnc.Discord` | Discord | Plain text. Markdown OK (Discord renders it). |
| `com.linear.linear` | Linear | Markdown. Lists detected → bulleted output. |
| `com.atlassian.jira` (web) | Jira | Markdown. |
| `com.apple.Notes` | Apple Notes | Plain text with markdown headers preserved as `# Header` |
| Other / unknown | Default | Plain text, basic punctuation cleanup |

The detection is best-effort and surfaces a per-paste indicator: "Cursor detected — code-aware formatting." User can disable per-app rules globally (Settings → Dictation → Paste rules).

---

## 9. Library & Player

### Window structure decision

Two viable shapes:

| | Popover-only | Library + popover |
|---|---|---|
| Surface area | Single MenuBarExtra popover with a tab inside it for Library | Popover stays small (mode picker, Record button); Library is a separate `NSWindow` opened on demand |
| Cognitive load | Lower — one place for everything | Higher — but matches user mental model: menu-bar = quick actions, window = browse/play |
| Native feel | Popover is dismissed when click-out — playback inside it is fragile | NSWindow stays open during playback; AVPlayer can run uninterrupted |
| AVPlayer integration | Awkward (popover layout is constrained) | Natural (AVPlayerView is window-sized) |

**Choose: Library + popover.** The popover is small (mode picker, Record toggle, 3 most-recent sessions, "Open Library" button). The Library window is the native-feeling browsing surface with AVPlayer. This is open question §16 — flagged in case user prototypes both and changes mind.

### Library window layout

```
┌───────────────────────────────────────────────────────────────────┐
│ Library                                              ⌘N New rec  │
├───────────────────────────────────────────────────────────────────┤
│  [search "client onboarding"]                  [Filter ▾] [Sort ▾]│
├──────────────────────┬────────────────────────────────────────────┤
│                      │  Acme Co kickoff — Meeting Mode            │
│  Sidebar (sessions)  │  2026-04-30 14:30  ·  47 min  ·  FR        │
│                      │  ┌──────────────────────────────────────┐  │
│  • Acme Co kickoff   │  │ AVPlayerView with transport controls │  │
│    47 min · 4/30     │  │ ▶ ⏸  ◀⏸▶  -15  +15  1.0× ▾   00:12:34│  │
│                      │  └──────────────────────────────────────┘  │
│  • Quick fix idea    │  ┌──────────────────────────────────────┐  │
│    0:23 · today      │  │ Transcript (clickable)               │  │
│                      │  │                                      │  │
│  • Fri standup       │  │ [00:00] FR  Speaker 1: Bonjour...   │  │
│    32 min · 4/26     │  │ [00:14] FR  Speaker 2: Salut, ...   │  │
│                      │  │ [00:32] EN  Speaker 1: Switching...  │  │
│  • Daily journal     │  │  ◀ active segment highlights here    │  │
│    1:02 · 4/26       │  │                                      │  │
│                      │  └──────────────────────────────────────┘  │
│  ...                 │  [Summary] [Action items] [Audio] [Share] │
└──────────────────────┴────────────────────────────────────────────┘
```

### AVPlayer integration

```swift
let url = sessionDir.appendingPathComponent("audio.opus")
let player = AVPlayer(url: url)
player.rate = 1.0  // configurable: 0.5, 0.75, 1.0, 1.25, 1.5, 2.0
let playerView = AVPlayerView(frame: rect)
playerView.player = player
playerView.controlsStyle = .floating  // native macOS controls
```

Variable speed via `player.rate`; system handles pitch correction. Skip ±15 s via `player.seek(to: CMTimeAdd(player.currentTime, CMTimeMakeWithSeconds(±15, 600)))`.

### Click-to-jump from transcript

Each transcript line in the SwiftUI view binds a tap gesture:

```swift
.onTapGesture {
    let target = CMTimeMakeWithSeconds(segment.startSecs, preferredTimescale: 600)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
}
```

**Sync drift on long files:** AVPlayer reports position via `addPeriodicTimeObserver(forInterval:)` at 100 ms cadence. On a 3 hr session this is 108k position events — observed jitter is sub-50 ms in practice. The transcript-highlight binary-search lookup is O(log n) over `transcript.jsonl` segments, fast enough for real-time on a 30-min transcript. **Risk:** AVPlayer's Opus playback on macOS 12.x has been observed to drift after seeks past 1 hr; mitigation is a forced `player.replaceCurrentItem(with:)` if drift exceeds 200 ms (re-load the file from the seek point).

### Live transcript follow

While playing, scroll the transcript view to keep the active segment in view. SwiftUI `ScrollViewReader` + `scrollTo(segmentID, anchor: .center)`. User can manually scroll; auto-follow disengages until they click a segment (then re-engages).

### Search

Two layers:

| Layer | Index | Latency | Best for |
|---|---|---|---|
| **FTS5** | SQLite `transcripts_fts` virtual table; rebuilt on transcript write | Sub-10 ms for 1k sessions | Exact phrase, keyword, simple boolean |
| **Semantic** | OpenAI `text-embedding-3-small` (1536-dim) per segment, stored in SQLite as BLOBs; cosine sim in pure Swift on query | 50–200 ms for 1k sessions | "What did Marc say about pricing" — fuzzy intent |

Embeddings cost: ~$0.02 per 1M tokens; a typical 30-min meeting transcript is ~10k tokens; 1k sessions = ~$0.20 total to backfill. Lazy: embed on first search query that asks for semantic, not on transcript write.

Embedding provider is open question §16 — Voyage AI's `voyage-3` is competitive; `text-embedding-3-small` is the safe default.

### Filtering

| Filter | Backed by |
|---|---|
| Date range | SQLite `recorded_at` index |
| Mode (Meeting / Dictation / Voice Note) | SQLite `mode` column |
| Duration (>5 min / <5 min) | SQLite `duration_secs` index |
| Language | Detected primary language stored on session row |
| Has summary / has actions | SQLite columns set on AI-processing complete |

### Bulk ops

Multi-select rows (Cmd+click). Available bulk actions:

- **Delete** — remove session folder + SQLite row. Undo within 30 s via toast.
- **Export** — combined Markdown of all selected, or zip-bundle.
- **Re-process with AI** — rerun the LLM stage with current provider. Useful when switching providers or improving prompts. Surfaces a single confirmation with combined cost estimate.

---

## 10. Sharing

Adapted from Jarvis Studio §8. Simpler here — no annotation export, no video transcode.

### Export formats

| Format | Contents |
|---|---|
| **Markdown** (.md) | YAML frontmatter (date, duration, language) + summary + action items + transcript with `[mm:ss]` timestamps |
| **Plain text** (.txt) | Transcript only, no formatting |
| **Audio** (.opus) | The archive Opus file as-is |
| **Audio + transcript bundle** (.zip) | `audio.opus` + `transcript.txt` + `summary.md` + `README.txt` (link instructions) |

### S3-compatible upload

```
[Share] → modal:

┌─────────────────────────────────────────────┐
│ Share session                               │
├─────────────────────────────────────────────┤
│  Include:                                   │
│   ☑ Audio                                   │
│   ☑ Transcript                              │
│   ☑ Summary                                 │
│   ☐ Action items                            │
│                                             │
│  Format: ( ) Direct download (audio file)   │
│          (•) Bundle (zip — all selected)   │
│          ( ) Markdown only                  │
│                                             │
│  Expiration: [ 7 days ▾ ]                   │
│                                             │
│  Estimated upload size: 8.2 MB              │
│              [ Cancel ] [ Share ]           │
└─────────────────────────────────────────────┘

→ async background job (mirroring Jarvis Studio §8 durable share-queue):

   1. Build artifact (zip if bundle)            ~1 s
   2. Multipart S3 upload                       30 s – 5 min
   3. Generate presigned GET URL                <1 s
   4. Append to local "Shared" library tab     <1 s
   5. Toast: "Link copied — expires in 7 days"
```

S3 endpoint configuration: per Jarvis Studio §8 wireframe (RustFS / MinIO / R2 / B2), minus the "viewer page" rejection — same stance here, no hosted viewer.

### Durable share queue

Same `share-queue.json` pattern from Jarvis Studio §8, atomic-write protected. Per-stage resume on app relaunch. Multipart upload `upload_id` expiration handled identically (`NoSuchUpload` → re-upload from local artifact).

### Local "Shared" library tab

Inside the Library window, a "Shared" filter shows sessions with active shares. Each row has:

- Copy link
- Re-share (re-presigns, extends expiration)
- Revoke (deletes the bucket object — recipients get 403 on next click)
- Open (opens the session for replay)

### No-hosted-viewer rationale

Same as Jarvis Studio §8: presigned URLs point at the raw audio file or the markdown bundle; recipients open in their browser (`<audio>` plays the .opus natively in Chrome/Safari/Firefox; .md downloads or renders if a browser extension is installed). No `/v/{key}` HTML page, no hosted UI.

For the bundle (.zip) recipient flow: link → download → unzip → open `summary.md` in their preferred Markdown viewer / `audio.opus` in QuickTime / a browser. The README.txt inside the zip explains the structure in three lines.

### Share-before-process guard

Cannot Share until transcription **and** summary (Meeting / Voice Note modes) are complete. Override available: "Share audio only" — skips waiting, exports just the .opus. Useful when the user wants to hand the recording to someone who'll do their own AI processing.

### Privacy on share

The presigned URL is the entire access control. Document this clearly in the Share modal's small print: "Anyone with this link can access the file until expiration. Don't share in public channels." No password protection in v1 (would require a hosted viewer to prompt — rejected).

---

## 11. External Dependency Lifecycle

Adapted from Jarvis Studio §3.1. Shorter here: no local-model bootstrap (no whisper-rs, no Whisper Local download UX).

### Five-state model

```
            ┌──────────────┐
            │ unconfigured │ ◀── default at first launch
            └──────┬───────┘
                   │ user enters config
                   ▼
            ┌──────────────┐
            │  configured  │ ◀── credentials/endpoint stored, never tested
            └──────┬───────┘
                   │ Test connection / first use
                   ▼
            ┌──────────────┐  transient failure (timeout, 5xx)
            │   reachable  │ ───────────────────────────────────┐
            └──────┬───────┘                                    ▼
                   │                                      ┌──────────────┐
                   │ persistent failure (auth, quota,     │   degraded   │
                   │  endpoint dead)                      └──────┬───────┘
                   ▼                                             │ recovery probe
            ┌──────────────┐                                     │
            │ unavailable  │ ◀── disabled in selectors,    ──────┘
            └──────────────┘     banner with cause + next step
```

### Per-dependency contract

| Dependency | Configured by | Test op | Probe op | Bootstrap |
|---|---|---|---|---|
| Anthropic | API key | minimal `messages` call (1 token) | per-request error | n/a |
| OpenAI | API key | `GET /v1/models` | per-request error | n/a |
| OpenRouter | API key | `GET /v1/models` | per-request error | n/a |
| Ollama | endpoint URL + optional bearer | `GET /api/tags` (auth-checked) | `GET /api/version` | `POST /api/pull` (when user picks an unpulled model — surface progress) |
| Deepgram | API key | minimal `listen` call (50 ms silent audio) | per-request error | n/a |
| OpenAI Whisper | API key (shared with OpenAI provider) | minimal `audio/transcriptions` (silent 50 ms clip) | per-request error | n/a |
| AssemblyAI | API key | `GET /v2/transcript?limit=1` | per-request error | n/a |
| S3 / MinIO / R2 | endpoint + key + bucket | `HEAD` bucket + 1-byte `PutObject`/`DeleteObject` | `HEAD` bucket | n/a |

### State persistence

`~/Library/Application Support/KosmoNotes/dependencies.json`. Atomic-write (`tmp + fsync + rename`). Corrupt-on-read = treat as `{}` + log; never crash. Status pill in every Settings panel reflects the persisted state.

### Uniform failure UX

| Failure | Backoff | Final state | UX |
|---|---|---|---|
| 4xx auth | none — no retry | unavailable | "Authentication failed: <message>. [Edit credentials]" |
| 429 rate-limited | exponential 250 ms → 8 s, 5 retries | degraded | "<dep> rate-limited. Retry in <Retry-After> s." Toast + pill update |
| 5xx server | 3 retries × 250 ms | degraded | "<dep> appears unhealthy" banner |
| DNS / connection refused | none | unavailable | Literal error + [Test again] button |
| Ollama model not pulled | n/a | degraded (per-model) | "Pull `qwen2.5:14b` (~9 GB)? [Pull on server]" with progress |

---

## 12. Privacy & Security

The pivot's most uncomfortable spec section, stated honestly.

### Per-feature data flow

| Feature | Where data goes | What is sent |
|---|---|---|
| **Recording at rest** | Local disk only | Opus audio, JSONL transcript, MD summary |
| **Transcription** | Cloud (Deepgram / OpenAI / AssemblyAI) | Full audio. Provider-specific retention policies apply (see Settings → Privacy for active links). |
| **AI processing (LLM)** | User's chosen provider | Full transcript + system prompt. Anthropic / OpenAI / OpenRouter retention applies per their TOS. **Ollama: stays on user's hardware.** |
| **Embeddings (semantic search)** | OpenAI by default (open question §16) | Per-segment text. Embedded once, then local. |
| **Sharing** | User's chosen S3-compatible endpoint | Audio + transcript + summary as configured by share modal |

### The privacy claim, honestly

The product's privacy posture is **partial**. The strong version is:

> Audio leaves the machine to a US-based or EU-based transcription provider every time. The LLM stage can be local via Ollama, or cloud. The user's choice of LLM provider controls one dimension; the transcription dimension is always cloud.

This is documented in:
- README ("Privacy" section)
- Settings → Privacy panel (one-paragraph plain-language explainer)
- First-launch walkthrough (one-line callout)

Users who require fully-local audio processing should be redirected to Macwhisper / Aiko / etc. We are not that product. Ship the honest framing; don't dress up "your LLM is local!" as the whole privacy story.

### Keychain usage

All secrets live in macOS Keychain via `Security.framework`:

```
Service: dev.kosmonotes.studio
Accounts:
  - openai-api-key
  - anthropic-api-key
  - openrouter-api-key
  - deepgram-api-key
  - assemblyai-api-key
  - ollama-bearer-token (optional)
  - s3-secret-access-key
```

Configuration JSON stores only references (the Account name); `KeychainAccess` SwiftPM package wraps the API for ergonomics.

### Audio at rest

**Choice: not encrypted by default.** Reasoning:
- The user's macOS account already encrypts the disk (FileVault, default on for the personal-use audience).
- Adding app-level encryption costs UX (key management on first launch, recovery flow, key escrow questions) for marginal gain over FileVault.
- An attacker with disk access has bigger problems.

Document this clearly: "Recordings are stored unencrypted in `~/Library/Application Support/KosmoNotes/recordings/`. Rely on FileVault (System Settings → Privacy & Security → FileVault) for at-rest encryption."

If a user explicitly wants per-file encryption, point them to a future feature flag (deferred per §2). Don't ship a half-baked optional encryption layer in v1.

### Network security

- All HTTPS. `URLSession` with `URLSessionConfiguration.default` — TLS 1.2+ enforced by macOS.
- No HTTP fallback for any provider endpoint (validation at config time).
- Self-hosted Ollama allowed over HTTP **only** if the host is `localhost` or in a private IP range (10.x, 172.16-31.x, 192.168.x). Public-IP HTTP is refused with a clear error.

---

## 13. Configuration

### Hybrid persistence

| Type of data | Persistence |
|---|---|
| User preferences (window size, default mode, hotkeys, last-used provider) | `UserDefaults` — built-in macOS pattern, KVO-friendly |
| Provider config (endpoint URLs, model names, enabled flags) | `KosmoNotes.config.json` in `~/Library/Application Support/KosmoNotes/` — atomic-write, version-tagged |
| Secrets | macOS Keychain |
| Session metadata | SQLite (`sessions.sqlite`) — index, FTS5, embeddings BLOBs |
| Transcripts, summaries, audio | Filesystem (`recordings/<sid>/`) — source of truth |

`UserDefaults` for preferences (small, frequently-read), JSON for typed configuration (provider-shape data is structurally richer than a flat key-value), SQLite for queryable session data.

### Settings UI structure

Five tabs in the Settings window:

```
┌─────────────────────────────────────────────────────────┐
│ Settings                                                │
├─────────────────────────────────────────────────────────┤
│ [AI Providers] [Ollama] [Transcription] [Privacy] [Hotkeys] │
├─────────────────────────────────────────────────────────┤
│  ...  panel-specific fields ...                         │
└─────────────────────────────────────────────────────────┘
```

**AI Providers** — Anthropic / OpenAI / OpenRouter API keys; default model picker; Test connection per provider; cost-cap field.

**Ollama** — Endpoint URL, optional bearer, default model (auto-populated from `/api/tags`), API mode (native vs OpenAI-compat), Test connection.

**Transcription** — Provider radio (Deepgram default, Whisper, AssemblyAI), API keys, language preference (auto-detect default), diarization toggle.

**Privacy** — One-paragraph honest explainer (linked above), audio-at-rest checkbox (currently disabled with "Use FileVault" note), data-deletion button ("Delete all sessions" — modal confirmation, irreversible).

**Hotkeys** — Three rows for the three modes; capture via `KeyboardShortcuts` SwiftPM package or hand-rolled `NSEvent` monitor.

### Manual binary-share workflow

The hand-shared `.app` flow has a subtle config-portability issue:

- **Sender's API keys are in their Keychain — they don't transfer.**
- **Sender's Ollama URL transfers** if it's in `KosmoNotes.config.json`.
- **Recipient must re-enter all keys on first launch.**

This is correct (you don't want to leak API keys across users), but document it explicitly in the "Sharing the app binary" instructions: "After dropping KosmoNotes.app into Applications, open Settings and add your own API keys. The sender's keys are NOT included."

### Migration

Schema versioning in `KosmoNotes.config.json`:

```json
{
  "schema_version": 1,
  "providers": { ... },
  "transcription": { ... },
  ...
}
```

On version bump, run a migration function. v1 ships with `schema_version: 1`; future bumps are problems for future versions of the doc.

### Config schema sketch

```json
{
  "schema_version": 1,
  "data_dir": "~/Library/Application Support/KosmoNotes",
  "providers": {
    "anthropic":  { "enabled": true,  "api_key_keychain_account": "anthropic-api-key", "default_model": "claude-sonnet-latest" },
    "openai":     { "enabled": false, "api_key_keychain_account": "openai-api-key" },
    "openrouter": { "enabled": false, "api_key_keychain_account": "openrouter-api-key" },
    "ollama":     { "enabled": false, "endpoint_url": "http://localhost:11434", "bearer_keychain_account": null, "default_model": null, "api_mode": "native" }
  },
  "transcription": {
    "provider": "deepgram",
    "deepgram":   { "api_key_keychain_account": "deepgram-api-key", "language": "multi", "diarize": true, "region": "eu" },
    "whisper":    { "model": "whisper-1" },
    "assemblyai": { "api_key_keychain_account": "assemblyai-api-key" }
  },
  "modes": {
    "default": "meeting",
    "dictation": {
      "ptt_or_toggle": "ptt",
      "max_duration_secs": 60,
      "force_cloud_llm": true,
      "llm_cleanup_enabled": true,
      "ai_provider_override": "anthropic"
    }
  },
  "ai": {
    "default_provider": "anthropic",
    "session_cost_cap_usd": 1.0
  },
  "sharing": {
    "backend": "s3",
    "endpoint_url": "https://storage.example.com",
    "bucket": "jarvis-shares",
    "access_key_id": "...",
    "secret_access_key_keychain_account": "s3-secret-access-key",
    "default_expiration_hours": 168
  },
  "hotkeys": {
    "meeting": "cmd+shift+r",
    "dictation": "cmd+shift+d",
    "voice_note": "cmd+shift+n"
  },
  "privacy": {
    "encrypt_audio_at_rest": false
  }
}
```

---

## 14. Risk Register

### Technical

| Risk | Severity | Mitigation |
|---|---|---|
| Core Audio Tap (14.4+) has edge cases per macOS minor version | **High** | Test on 14.4, 14.5, 14.6, 14.7, 15.x in CI matrix (manual GitHub Action with each as a self-hosted runner OR rely on user testing matrix). Have ScreenCaptureKit fallback path ready as `if #available(macOS 14.4)` else branch. |
| Transcription provider outage with no local fallback | **High** | Disk-queue accumulates audio (§5); queue drains on recovery. UI surfaces `degraded` state. The user can still record indefinitely; AI processing is delayed. **No local Whisper escape hatch by design.** |
| Ollama endpoint latency unfit for Dictation | Med | Force cloud LLM on Dictation (§8); Ollama warning on user override. |
| AVPlayer Opus playback drift on long files (>1 hr) | Med | Forced re-load on >200 ms drift detect. Fallback: convert to AAC at archive time if drift becomes systemic (rejects Opus-everywhere invariant; document if needed). |
| Accessibility paste fails in sandboxed apps | Med | Clipboard + Cmd+V fallback (§8). Surface "Pasted to clipboard" indicator. |
| FTS5 index becomes inconsistent after manual SQLite edits | Low | Rebuild button in Settings → Library: drops `transcripts_fts` and re-creates from `transcript.jsonl` sidecars. |
| macOS Gatekeeper friction on every install | **High** (positioning) | Document `xattr -d com.apple.quarantine /Applications/KosmoNotes.app` in the README. Send via channels that preserve extended attributes (Dropbox preserves; iMessage strips). Accept the cost — see §15 Decision Log. |

### Positioning

| Risk | Severity | Mitigation |
|---|---|---|
| "Privacy" claim weakened by cloud-only transcription | **High** | Honest framing in README, Settings → Privacy, first-launch flow (§12). Users misled into thinking it's fully local will churn loudly. |
| Multi-language edge over Granola is smaller than the brief suggests | Med | The actual differentiator is **summary-language flexibility** (UA call → FR summary), not raw transcription quality. Granola does French. The lead is dev-aware paste + Ollama, not language. Adjust marketing. |
| No code signing means every download triggers a Gatekeeper prompt | High | Same as above. Cost accepted; revisit if user count exceeds ~5 friends. |
| Wispr Flow's <0.5 s dictation latency wins on the dictation use case | Med | We accept ~3× the latency floor for multi-language and zero on-device-model engineering. Dictation Mode is a "nice secondary feature," not the lead. The lead is Meeting Mode. |

### Shipping

| Risk | Severity | Mitigation |
|---|---|---|
| Solo-dev v1 with library + player + sharing in 4–6 weeks is optimistic | **High** | Ship in three phases: (a) Meeting Mode + transcript only (~2 weeks), (b) AI summary + Library window (~2 weeks), (c) Dictation Mode + Sharing (~2 weeks). Each phase is shippable on its own. Cut Sharing first if running long. |
| Ollama, Deepgram, AssemblyAI integration concurrency is a death spiral | High | Ship with **one transcription provider** (Deepgram) and **one cloud LLM** (Anthropic) wired up. Other providers are framework-ready (Provider protocol exists) but disabled. Add OpenAI / Whisper / AssemblyAI / Ollama incrementally post-v1.0. |
| AVPlayer + transcript-sync is a UX rabbit hole | Med | v1 ships click-to-jump and live-follow. Drift correction is post-v1. |
| Hotkey conflict with system / other apps | Low | Three default hotkeys (Cmd+Shift+R/D/N) are unconventional enough to be safe. Settings → Hotkeys lets the user remap. |

---

## 15. Decision Log

### Settled

| # | Decision | What would cause revisit |
|---|---|---|
| D1 | Pure Swift / SwiftUI / AppKit. No Rust, no FFI, no webview. | macOS-specific framework limitations that force an FFI boundary (e.g., a transcription provider with only a C SDK — unlikely, all are HTTP). |
| D2 | Cloud-only transcription. No local Whisper. | OpenAI Whisper Pro Tier or equivalent at-cost local-quality model that's <500 MB and ships in our binary — none exists today. |
| D3 | Ollama via REST is the ONE local-LLM path. No bundled inference. | Apple ships an MLX framework with a stable model-pull API + sub-15-MB inference engine for chat models. Currently MLX requires the model artifacts live in the app or be downloaded — not v1-friendly. |
| D4 | No code signing, no notarization, no auto-update. Manual `.app` replacement. | User base exceeds ~10 people OR Apple's Gatekeeper friction increases (Apple has been tightening; if quarantine bypass becomes harder than `xattr -d`, revisit). |
| D5 | ~~macOS 12.3+ supported, 14.4+ preferred. <12.3 unsupported.~~ **Superseded 2026-05-03 — actual deployment target is macOS 14.0+** (`Package.swift` and `project.yml` pin `.macOS(.v14)`; `LSMinimumSystemVersion` blocks launch on <14). The 12.3–13.x "best-effort" path was never implemented — Recorder, Library, Settings, RecorderState, AudioEngine etc. are all gated behind `@available(macOS 14.0, *)`. Within 14.x: Core Audio Tap is 14.4+, ScreenCaptureKit audio fallback covers 14.0–14.3. See `CLAUDE.md` "Stack invariants" for the active contract. | Lowering to 12.3+ requires removing every `@available(macOS 14.0, *)` and replacing `@Observable` / `KeyboardShortcuts` 2.x APIs — large surgery. |
| D6 | Default transcription provider: Deepgram Nova-2 with EU residency on. | Deepgram pricing change, sustained outage, or a Whisper-class on-device model that ships under our binary-size limit. |
| D7 | Default LLM provider: Anthropic Claude Sonnet (latest). | Anthropic pricing change or capability regression vs OpenAI / OpenRouter. |
| D8 | No telemetry. No analytics. No auth. No payments. | Single-user product positioning changes (e.g., starts charging). Personal use only — no revisit expected. |
| D9 | Sharing via S3-compatible presigned URLs. No hosted viewer page. | Same Jarvis Studio §8 reasoning — no revisit. |
| D10 | Filesystem sidecars are source of truth; SQLite is rebuildable index. | Index becomes too expensive to rebuild (e.g., embeddings fully managed externally) — not v1. |
| D11 | Accessibility-API paste with clipboard fallback. | macOS deprecates `kAXSelectedTextAttribute` (no signal that this is happening). |
| **D12** | **v1.0 ships with ScreenCaptureKit-mixdown audio for ALL macOS 12.3+. Per-process Core Audio Tap is deferred to v1.1. Voice Note Mode and S3 Sharing also deferred to v1.1.** Decision applied 2026-05-02 after Critic round-2 review. v1.0 captures whole-system audio (Spotify and notifications too) — user mutes those manually before recording. Trade-off accepted to make Phase A timeline realistic for a Swift first-timer. | v1.1 evaluation reaches go-decision: per-process Tap can ship if 14.4+ Tap API quirks are well-understood; sharing can ship if a clear export channel is needed beyond Save-dialog. **Until then, design references in §5 (per-process Tap), §10 (S3 sharing), and §12 (Voice Note in mode list) describe the broader v1 vision, NOT what v1.0 ships. Implementation plan at `.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` is canonical for v1.0.** |
| **D13** | **`ChatMessage` uses structured content parts (`[Part]`) instead of a plain `String`.** Decision applied 2026-05-02 evening to support vision content (image frames extracted from screen.mp4) alongside text in LLM messages. `text` computed property preserves display compatibility. Both Anthropic and OpenAI providers serialize parts per their respective APIs (content-block array vs image_url array). Single text-only parts fall back to plain string serialization for maximum API compatibility. | Provider adds a new content type that requires structural changes (e.g., tool-use blocks in requests — already handled by a future `Part.toolResult` case). |
| **D14** | **Screen recording reinstated as opt-in feature (2026-05-02 evening). Owner reversed the design-doc's "no-screen-recording" decision after using the audio-only build.** `ScreenRecorder` actor uses SCStream → AVAssetWriter (H.264 video + AAC audio, 24 fps, 4 Mbps) to write `screen.mp4` alongside audio. `AppSettings.recordingMode` controls opt-in (default: audio-only). `FrameExtractor` extracts JPEG frames at user-mentioned timestamps for vision-capable LLM chat. Cap: 3 frames per send. Screen content is never uploaded — used locally for frame extraction only. | User opts to make screen recording mandatory / always-on — revisit default. Frame extraction cap causes UX friction for long-form screen analysis — raise cap or introduce a frame picker UI. |
| **D15** | **v1.0 transcription is batch, not streaming. Decision applied 2026-05-03 after audit `docs/audits/2026-05-03-architecture-code-spec-audit.md` §"streaming-vs-batch transcription drift".** `RecorderState.stop()` submits `audio.m4a` to the user-selected batch provider (Whisper / AssemblyAI / Deepgram batch) once the recording finishes. The streaming infrastructure (`TranscriptionKit/DeepgramProvider.openResilientSession`, `ReconnectingSession` with 5-s ring buffer + exponential backoff) is **kept in tree** and unit-tested, but **not wired into the recorder UI**. Reasons: (a) batch is end-to-end working and shipped; (b) streaming requires a PCM tee from `CaptureSession` plus live-transcript UI surface, neither of which exists in v1.0; (c) for a single-user product without live captions in v1.0, batch latency (≤5 s after stop on 5-min recording) is good enough. AC-7 ("Deepgram streaming … within 5 s of stop") is reinterpreted as a batch-completion budget for v1.0. **Revisit condition met 2026-06-12** — the owner requested live captions + live chat, and the PCM tee now exists (`LivePCMSink`/`LiveSinkDelivery` in `CaptureSession`, shipped with the always-on-capture work; a window-based live engine for Whisper-class providers also already shipped as `LiveTranscriptEngine`/`RecorderLiveTee`, display-only). Superseded by **D17** for v1.x. Batch remains the shipped v1.0 behavior and the universal fallback. | ~~v1.0 ships, owner wants live captions during recording, and a CaptureSession PCM tee is on the v1.1 roadmap.~~ Met — see D17. |
| **D16** | **WhisperKit reinstated as opt-in fifth transcription provider (2026-05-04). Owner reversed the cloud-only invariant after using v0.0.2.** `Sources/TranscriptionKit/WhisperKitProvider.swift` is a `BatchTranscriptionProvider`-conforming actor wrapping `argmaxinc/WhisperKit` (resolved 0.18.0). Models are downloaded on demand via `WhisperKitModelManager` into `~/Library/Application Support/KosmoNotes/whisperkit/<variant>/`. Settings → Transcription gets a "Local — WhisperKit" section with picker + Download/Delete buttons + progress bar, exposing the full HuggingFace catalogue (tiny → large-v3-turbo + distil variants). The active provider stays at whatever cloud option the user last chose — **WhisperKit is NOT auto-selected on download**. `RecorderState.start` pre-flights the WhisperKit case (variant picked + downloaded) so users can't start a recording that will fail because no model is on disk. Bundle stays under 15 MB (only the framework ships, weights are runtime downloads). `WhisperKit.recommendedModels()` is surfaced as a hint near the picker. | Argmax pivots WhisperKit to a license that conflicts with personal-binary distribution (currently MIT). Apple ships a comparable on-device transcription API at parity with Whisper (could simplify by removing the third-party dep). User opts to make WhisperKit the default — revisit "default cloud" stance. Parakeet (NVIDIA TDT via FluidInference/swift-parakeet-mlx) becomes a clearly-better local option — add it as a sixth provider. |

| **D17** | **Live transcription + live chat accepted as the v1.x direction (2026-06-12).** Supersedes D15's "streaming stays unwired" stance — its revisit condition is met. Two-source design per `docs/plans/2026-06-12-live-chat-transcription-design.md`: (a) **Deepgram WebSocket streaming** (`openResilientSession`, kept alive since D15 and since hardened — retry-budget reset, pre-send ring buffer, per-reconnect timestamp offsets) becomes the primary live source behind a fan-out `LivePCMSink` with mic/system source separation; (b) the already-shipped **window engine** (`LiveTranscriptEngine`, 5 s window / 3 s cadence) remains the fallback for Whisper-class providers. Prerequisites before wiring: KeepAlive frames, drain-until-Metadata finish, terminal-error surfacing (2026-06-12 audit T-M3/T-M5/T-M6). Live finals persist incrementally via `TranscriptStore` + periodic FTS re-index (idempotent DELETE-then-INSERT), ending the current "discard live result, re-transcribe batch" behavior. Live chat ships as a floating `NSPanel` whose `ChatState` injects the current live transcript per turn. **Privacy/cost note:** streaming sends audio to the provider *during* the meeting — the cost-cap gate moves from stop-time to recording start, and §12's posture text must say so. | Streaming per-minute cost materially exceeds batch for the owner's usage; Deepgram streaming reliability regresses; or WhisperKit gains true streaming (would demote the window engine and possibly the cloud default). |
| **D18** | **Tool use (function calling) added to AIKit (2026-06-12).** Extends D13 exactly along its anticipated path ("a future `Part.toolResult` case"). `ChatMessage.Part` gains `.toolUse`/`.toolResult`; new `ToolSpec`/`ToolCall`/`JSONValue` types; `AIProvider` gains `chat(messages:tools:config:) -> ChatResponse{parts, stopReason}` with a default implementation wrapping the existing `chat()` so non-tool call sites are untouched. A provider-agnostic **`ToolLoopEngine`** generalizes the proven `AgentRunner` loop (max iterations, byte budget, `is_error` folding, event stream) for all four providers; `AgentRunner`'s bespoke Anthropic HTTP client is eventually retired onto it. First tools: `search_live_transcript`, `search_transcripts` (FTS), `search_knowledge_base` (D19), `search_code` (confined `rg`), `get_screen_frame`. | Provider tool dialects diverge enough that the shared abstraction leaks (e.g. OpenAI deprecates `tool_calls` shape); or chat latency demands SSE streaming before the loop is usable (streaming remains deferred — revisit order if tool turns feel too slow). |
| **D19** | **Knowledge base added (2026-06-12): user-attached documents + code folders, searchable by the assistant.** Migration `v4_knowledge_base`: `kb_sources` (document \| code_folder, plain path — sandbox is OFF, no bookmarks), `kb_documents` (mtime/size change detection), `kb_chunks_fts` (FTS5; plain `unicode61 tokenchars '_'` for code — porter stemming is wrong for identifiers), `kb_embeddings` (chunked, reusing `EmbeddingMath.pack`, 1536-dim). New `KnowledgeBaseStore` actor mirrors `SessionStore`. Extraction: `String(contentsOf:)` for text/markdown/code, **PDFKit** for PDF (system framework — zero new deps, D1 intact). Embeddings are opt-in per source and FTS5-primary (same degradation philosophy as session semantic indexing); embedding spend hooks into `costCapUSD`. **D10 invariant preserved:** source files remain the source of truth; all KB rows are rebuildable via `reindexAll()`. | KB grows past what cosine-in-Swift over all chunks handles (revisit the rejected sqlite-vec); PDFKit extraction quality proves inadequate (consider Vision framework OCR); or indexing cost/latency on large code folders forces a switch to on-demand `rg`-only for code. |
| **D20** | **Ollama gains a third API mode: Anthropic-compat `/v1/messages` (2026-06-12).** Extends §7's "OpenAI-compat vs. native — picked at runtime" decision to three modes (`native` \| `openaiCompat` \| `anthropicCompat`). Ollama ≥ 0.14 implements the Anthropic Messages dialect including tool_use/tool_result blocks, SSE, and base64 vision ([docs](https://docs.ollama.com/api/anthropic-compatibility)). Implementation: extract the Anthropic request/response codec shared by `AnthropicProvider` and the new Ollama mode (base URL is the only difference), giving local models the full D18 tool loop with no second serialization path — and `AgentRunner`/`ToolLoopEngine` a fully-local backend. Caveats recorded: no `tool_choice`; never call `count_tokens` (known server hang, ollama#13949); usage numbers are approximate — budget by bytes; `.native` stays as the <0.14 fallback with a clear 404 error. CLAUDE.md's "two modes" stack-invariant line updates together with the implementing change. | Ollama's compat layer churns breaking-ly between releases (it is young); or Ollama ships `tool_choice`/`count_tokens`, simplifying the caveats. |
| **D21** | **Speaker echo cancellation defaults ON for meeting capture (2026-06-12).** Per `docs/plans/2026-06-12-echo-cancellation-fix-plan.md`, `AudioEngine` can enable Apple VoiceProcessingIO with AGC disabled and other-audio ducking minimized; `CaptureSession` routes screen-mode mic capture back through AVAudioEngine when echo cancellation is enabled because SCStream has no AEC control. `MicPathPlan` records the SCStream-vs-AVAudioEngine decision, and Settings → Transcription exposes a reversible toggle. Dictation stays outside this change so raw close-mic dictation audio is not voice-processed. | VoiceProcessingIO audibly degrades important ambient recordings; HAL contention regresses despite the start-order settle and supervisors; or Apple adds an SCStream microphone AEC control. |

### Brainstorm-recorded — do not relitigate

(Equivalent to Jarvis Studio §12.) The pivot from Jarvis Studio → Jarvis Note happened on 2026-05-02 after four review rounds, three stack pivots (Tauri → iced → Swift), and a working v0.1.1. The decisions above are post-pivot. Reverting to a Rust core or webview frontend is **out of scope** for v1 and would invalidate the entire spec. Screen recording was originally deferred but was re-admitted as an opt-in feature (D14); this does not constitute a full product pivot.

---

## 16. Open Questions

Unresolved items that need user input before / during implementation. (Items 1–5 date from the original draft; 6–8 added with the 2026-06-12 revision.)

1. **Primary transcription provider — Deepgram, AssemblyAI, or Whisper?** This doc recommends Deepgram for streaming + EU residency + UA/RU quality. Confirm before wiring (post-§14 shipping note: ship one, defer the others).

2. **Embedding provider for semantic search.** Default option: OpenAI `text-embedding-3-small`. Alternative: Voyage AI `voyage-3` (slightly better quality, slightly higher cost). Both are cloud — privacy posture unchanged from §12.

3. **Popover-only vs. popover + Library window.** §9 recommends both surfaces. Cost: Library window adds AppKit `NSWindow` work (~3 days). Popover-only is faster but compresses the playback / browsing UX into a too-small surface. Confirm before §9 implementation.

4. **Third-party OpenAI-compat endpoints (Together / Groq / Fireworks) in v1?** The Provider abstraction supports them today via the OpenAI provider with a custom base URL. Question is whether to surface them in the Settings UI (a "Custom OpenAI-compatible endpoint" panel) in v1 or defer.

5. **Final product name.** Working title: Jarvis Note. Other options surfaced in conversation: "Whisper Pad" (conflicts with OpenAI Whisper), "Voicelet", "Pulse", "Threadnote", "Echo" (generic). Pick before first beta share.

6. **Live FTS visibility (D17).** Incremental indexing makes an in-progress session appear in Library search mid-recording. Feature or confusion? Either way, `clearAllSessions` needs its active-recording guard first (2026-06-12 audit L-M6, open).

7. **KB embedding defaults (D19).** Proposed: FTS-only for code folders, embeddings opt-in per document source. Confirm before the Settings UI is built — flipping the default later orphans spent embedding cost.

8. **Live-chat context budget (D17).** Last N minutes verbatim + tool-based retrieval for earlier content — pick N (proposal suggests 10–15 min) and whether the budget is tokens or bytes (AgentRunner precedent: bytes).

---

## 17. References

- Jarvis Studio design doc (`docs/plans/2026-05-01-jarvis-studio-design.md`) — superseded for new development; retained as reference for share-pipeline (§8) and dependency-lifecycle (§3.1) patterns.
- [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine) — mic capture
- [Core Audio Tap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap) — system audio (14.4+)
- [ScreenCaptureKit audio](https://developer.apple.com/documentation/screencapturekit) — fallback for 12.3–14.3
- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) — playback with variable speed
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite wrapper with FTS5 support
- [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) — Keychain wrapper
- [Deepgram API](https://developers.deepgram.com/docs/) — streaming + Nova-2
- [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md) — `/api/chat` + `/api/tags`
- [Ollama Anthropic compatibility](https://docs.ollama.com/api/anthropic-compatibility) — `/v1/messages` incl. tool use (D20)
- [Anthropic API](https://docs.claude.com/en/api/) — Claude Sonnet messages API
- [Deepgram KeepAlive](https://developers.deepgram.com/docs/audio-keep-alive) + [Close Stream](https://developers.deepgram.com/docs/close-stream) — streaming prerequisites for D17
- Live transcription + live chat + tools proposal: `docs/plans/2026-06-12-live-chat-transcription-design.md` (D17–D20 implementation detail)
