# Live transcription + live chat with tools — design research

**Date:** 2026-06-12 · **Status:** research/proposal — needs a dated revision of the main design
doc (`docs/plans/2026-05-02-jarvis-note-design.md` §15 Decision Log) before implementation, per
repo rules ("new features get a design pass, not silent accommodation").

## 1. Feature statement

While a meeting recording is in progress:
1. **Live transcript** — a continuously-growing, timestamped transcript visible in real time
   (not the current 48-char menu-bar line, and not only after stop).
2. **Live chat** — ask questions *during* the recording and get answers grounded in what has
   been said so far.
3. **Tools / knowledge base** — the assistant can call tools mid-turn: search the live
   transcript, search a user-attached code folder, search user-added documents (markdown, text,
   PDF) ingested into a local knowledge base.

## 2. What already exists (research findings, file:line verified)

The surprising result of the code research: **most of the hard parts are already built** — they
are just disconnected from each other.

### 2.1 Two live-transcription stacks

**A. Deepgram WebSocket streaming stack — fully built, unit-tested, NOT wired** (the comment at
`App/State/RecorderState.swift:39-42` defers it to v1.1):
- `TranscriptionSession` actor with `events: AsyncStream<TranscriptSegment>`, `send(pcm)`,
  `finish()` (`Sources/TranscriptionKit/Provider.swift:30-129`).
- `DeepgramProvider.openResilientSession` (`DeepgramProvider.swift:55-74`) — production entry
  point; `interim_results` already on by default (`Models.swift:74`), `endpointing=300`.
- `ReconnectingSession` — 5 s ring buffer, backoff, retry-budget reset, timestamp-offset replay
  across reconnects (all recently fixed: H6, T-M1, T-M2 in the 2026-06-12 audit).

**B. Window-based polling engine — wired today, Whisper-class only:**
- `LiveTranscriptEngine` actor (5 s window / 3 s cadence) + `LiveWindowExporter` (m4a re-encode
  per tick) + `RecorderLiveTee: LivePCMSink` (PCM → temp CAF → ticks)
  (`Sources/TranscriptionKit/LiveTranscriptEngine.swift:32`, `App/State/RecorderLiveTee.swift:51`).
- Gate: `AppSettings.makeLiveProvider()` returns non-nil only for `.openaiWhisper` /
  `.whisperKit` (`App/State/AppSettings+Resolvers.swift:52-68`). **Deepgram — the product
  default — gets no live transcript at all.**
- Output: `LiveTranscriptState` with timestamped stable/draft units
  (`LiveTranscriptTypes.swift:42-57`) → `RecorderState.liveTranscriptStableText/MutableText`
  (`RecorderState.swift:94-100`) → rendered as ONE truncated 48-char disabled `NSMenuItem`
  (`KosmoNotesApp.swift:1026-1060`). Display-only; discarded at stop (`RecorderState.swift:897`)
  and the whole file is re-transcribed batch.

### 2.2 PCM tee — the audio side is solved

- `LivePCMSink` protocol + bounded `LiveSinkDelivery` (drop-oldest, `bufferingNewest(32)`)
  (`Sources/CaptureKit/CaptureSession.swift:33-133`); injected via
  `CaptureSession.init(config:liveSink:)` (`:451`); mic funnel `enqueueMicBuffer` (`:866-890`)
  tees every mic buffer to the sink *after* the disk writer — a second audio consumer during
  recording is exactly how the current live tee works.
- Two real gaps: (a) the sink receives **mic AND system audio with no source tag**
  (`:1181-1184`, `:1214-1217`, `:1243-1246`) — a live STT consumer needs mic-only or tagging;
  (b) there is **one** `liveSink` slot — running captions + window engine together needs a
  fan-out sink.

### 2.3 Tool use — a working agentic loop already exists in the App layer

- `AgentTool` protocol (`name/description/inputSchema/execute`) with `ReadFileTool`,
  `WriteFileTool`, allowlisted `BashTool` (grep/rg/find), workspace confinement
  (`App/State/AgentTool.swift:12-392`).
- `AgentRunner` actor — full Anthropic `tool_use`/`tool_result` loop: max 12 iterations, 200 KB
  transcript budget, cooperative stop, mid-run injection, event stream to UI
  (`App/State/AgentRunner.swift:49-322`). **Anthropic-only, raw `[String: Any]`, bespoke HTTP —
  disconnected from AIKit.**
- Adding tools is purely additive: register in `AgentSessionState.swift:178-182`; dispatch is
  by name (`AgentRunner.swift:196`).

### 2.4 AIKit — no tool support, no streaming

- `AIProvider` = one method returning bare `String` (`Sources/AIKit/Provider.swift:6-9`).
- `ChatMessage.Part` = text | image only (`Models.swift:5-72`); no tool parts, no stop reason.
- Concrete hazards for tool use: `OpenAIProvider.parse` decodes `content` as **non-optional**
  (throws on any `tool_calls` response; OpenRouter shares the parser), `AnthropicProvider.parse`
  silently **drops non-text blocks** (`:141-144`).

### 2.5 Chat — context stuffing, plus an existing "live snapshot" affordance

- `ChatState.send()`: FTS auto-context (`searchTranscripts`, now `ORDER BY rank`) → attach
  sessions → **full transcripts concatenated into the system prompt** (no token budget) →
  single non-streaming `chat()` (`App/State/ChatState.swift:239-292`, `:616-668`).
- `sendSnapshot()` already chats over the last ~60 s of an in-progress recording
  (SnapshotMaker concat → Whisper) but drops attached-session context (`systemPrompt: nil`,
  `:360`) and needs an OpenAI key.
- In-progress sessions are invisible to all retrieval: `transcript.jsonl`, FTS, and embeddings
  are written **only post-stop** (`RecorderState.swift:712-758`).
- Chat window is plain AppKit (`KosmoNotesApp.openChat()`, `:841-891`) — adding a floating
  live `NSPanel` requires no Scene refactor.

### 2.6 Storage / KB foundations

- GRDB migrations v1–v3, raw SQL, additive (`Sources/StorageKit/Database.swift:130-173`).
  FTS5 `porter unicode61`, one row per session. Embeddings: **one 1536-dim vector per session,
  transcript truncated at 6000 chars** (`RecorderState+SemanticIndex.swift:29`) — no chunking.
- **Sandbox is OFF** (`project.yml ENABLE_APP_SANDBOX: "NO"`, empty entitlements) — a KB/code
  folder is a plain stored path, no security-scoped bookmarks; folder-picker pattern exists
  (`SettingsView.swift:1674-1684`).
- No PDF/text extraction anywhere yet; `PDFKit.PDFDocument(url:).string` is the zero-dependency
  option (system framework — consistent with stack invariants).

## 3. Proposed architecture

```
                       ┌──────────────────────────────────────────────┐
   CaptureSession      │                RecorderState                 │
   mic PCM (mono       │                                              │
   48kHz Float32)      │   LiveTranscriptHub (@MainActor observable)  │
        │              │      stable units + draft unit, timestamped  │
        ▼              │      ▲                    ▲                  │
   FanOutPCMSink ──────┼──────┤                    │                  │
    ├─ RecorderLiveTee │  StreamingLiveSource   WindowLiveSource      │
    │   (window engine,│  (Deepgram WS:         (existing engine:     │
    │    Whisper-class)│   PCM→16k Int16,        Whisper-class        │
    └─ StreamingBridge │   ReconnectingSession)  fallback)            │
                       └──────────────┬───────────────────────────────┘
                                      │ finals (incremental)
                          TranscriptStore.append (JSONL, already incremental)
                          + periodic SessionStore.indexTranscript (live FTS)
                                      │
                       ┌──────────────▼───────────────────────────────┐
                       │  Live Chat panel (NSPanel + ChatView slim)   │
                       │  ChatState(liveContext:) ── ToolLoopEngine   │
                       │     tools: search_live_transcript            │
                       │            search_transcripts (FTS, done)    │
                       │            search_code (rg, confined)        │
                       │            search_knowledge_base (FTS+cosine)│
                       │            get_screen_frame (FrameExtractor) │
                       └──────────────────────────────────────────────┘
```

## 4. Implementation phases

### Phase 1 — Real live transcript (foundation)

1. **Fan-out sink.** `FanOutPCMSink: LivePCMSink` broadcasting to N child sinks; replaces the
   single tee at `RecorderState.swift:385`. Add a source tag (mic vs system) to
   `LivePCMSink.receive` — or tee mic-only — so STT does not ingest interleaved system audio
   (today `RecorderLiveTee` writes both into one CAF: format-mismatch drops or timeline
   inflation, `RecorderLiveTee.swift:103-122`).
2. **Wire the dormant Deepgram streaming stack.** New `StreamingLiveSource` (App layer):
   `AVAudioPCMBuffer` (48 kHz Float32 mono) → `AVAudioConverter` → 16 kHz Int16 linear16
   `Data` → `ReconnectingSession.send`. Consume `events`; interim segments → draft unit,
   `is_final` → stable units. Extend `makeLiveProvider()` so `.deepgram` returns the streaming
   branch (`AppSettings+Resolvers.swift:52-68`). Keep the window engine as the Whisper-class
   fallback behind the same `RecorderLiveAdapter.SnapshotSource` interface.
3. **Prerequisite fixes from the 2026-06-12 audit (open items):**
   - **T-M3 KeepAlive** — `{"type":"KeepAlive"}` after ~5 s without audio (else NET-0001 on any
     mute/pause >10 s); injectable clock for tests.
   - **T-M5 finish drain** — replace the fixed 200 ms with drain-until-Metadata/server-close
     (2–5 s cap) and pass `{"type":"CloseStream"}` from production.
   - **T-M6 terminal errors** — `terminalError` property (or `AsyncThrowingStream`) so the UI
     can show "live transcription died" instead of silently freezing.
4. **Persist as you go.** `TranscriptStore.append` already accepts finals incrementally
   (`TranscriptStore.swift:39-43`); open the store at recording start, append finals live, and
   re-index FTS on a coarse timer (e.g. every 30 s) via the now-idempotent
   `Database.indexTranscript` (DELETE-then-INSERT). On stop: if live coverage is complete, skip
   (or LLM-clean) the batch re-transcription instead of discarding the live result
   (`RecorderState.swift:897`).
5. **UI.** A scrolling live-transcript view (popover or panel section) bound to the existing
   observable fields; the 48-char menu line stays as the at-a-glance summary.

### Phase 2 — Live chat over the growing transcript

1. **LiveTranscriptHub** — the one shared, timestamped source of truth in memory
   (stable units + draft), readable by UI, ChatState, and tools.
2. **ChatState live context.** When `recorder.status == .recording`: inject the current live
   transcript into the system prompt per turn (it is rebuilt on every `send()`, so staleness is
   per-turn only). Keep `sendSnapshot()` as the audio-accurate fallback; fix it to keep
   attached-session context (`ChatState.swift:360`).
3. **Live panel.** Floating `NSPanel` hosting a slim `ChatView` with a `ChatState` pinned to
   the active session — same construction pattern as `openChat()`.
4. **Budget.** Live transcripts grow unbounded; cap injected context (last N minutes verbatim +
   "earlier" via the search tool) — fixes the existing unbounded-stuffing problem at the same
   time (port AgentRunner's byte-budget idea).

### Phase 3 — Tool use in AIKit (generalize AgentRunner)

1. **Types** (`Sources/AIKit/Models.swift`): `JSONValue` (Codable, Sendable), `ToolSpec{name,
   description, parameters}`, `ToolCall{id, name, arguments}`; extend `ChatMessage.Part` with
   `.toolUse(ToolCall)` / `.toolResult(id, content, isError)`.
2. **Protocol**: `chat(messages:tools:config:) async throws -> ChatResponse{parts, stopReason}`
   with a default implementation wrapping the existing `chat()` — existing call sites
   (summaries, dictation, exporter) untouched.
3. **Providers**: Anthropic serialization ports verbatim from `AgentRunner.swift:166-300`;
   OpenAI/OpenRouter need `tools` + optional `content` + `tool_calls` decode (the shared parser
   currently throws on tool responses); Ollama gets tools primarily via the new
   **Anthropic-compat mode** (§ below) — native `/api/chat` `tools` stays as fallback with
   capability detection and a graceful "tools unsupported → plain chat" degrade.
3a. **Ollama Anthropic-compat (`/v1/messages`) mode.** Ollama ≥ 0.14 ships an
   Anthropic-Messages-compatible endpoint supporting tool use / tool_result blocks, SSE
   streaming, vision (base64 only), system prompts, and `stop_reason` values
   (`end_turn` / `max_tokens` / `tool_use`) — i.e. the same wire dialect as
   `api.anthropic.com` ([Ollama blog](https://ollama.com/blog/claude),
   [compat docs](https://docs.ollama.com/api/anthropic-compatibility)).
   - `OllamaProvider` today has two runtime modes — `.native` (`/api/chat`) and
     `.openaiCompat` (`/v1/chat/completions`) (`Sources/AIKit/OllamaProvider.swift:18-22`).
     Add a third: `.anthropicCompat` → POST `<endpoint>/v1/messages`, reusing
     `AnthropicProvider`'s serializer/parser with a configurable base URL instead of
     duplicating it (extract the Anthropic request/response codec into a shared helper both
     providers call).
   - **Payoff for the tool loop:** `ToolLoopEngine` + Anthropic codec works against local
     Ollama by changing only the base URL — local models get the full agentic loop without a
     second serialization path. The Agent console (`AgentRunner`, today hard-wired to
     `api.anthropic.com`) gets a fully-local backend almost for free once its HTTP layer takes
     a base URL.
   - **Caveats:** `tool_choice` is not supported (cannot force a tool); `count_tokens` is
     unsupported (and hitting unsupported endpoints has a known hang issue —
     [ollama#13949](https://github.com/ollama/ollama/issues/13949) — so never call it);
     token usage numbers are approximations (budget by bytes like AgentRunner, not by reported
     tokens); URL-referenced images unsupported (we already send base64 — fine); requires
     Ollama ≥ 0.14 — keep `.native` as the compatibility fallback and surface a clear error
     when `/v1/messages` 404s.
   - Settings: one `ollamaAPIMode` enum (`native | openaiCompat | anthropicCompat`) following
     the existing `Defaults` + `didSet` pattern (`AppSettings.swift:322-331`), surfaced in
     Settings → AI Providers next to the endpoint field.
   - CLAUDE.md stack invariant "Ollama is REST-only … v1 supports both `/v1/chat/completions`
     and `/api/chat`" extends to three modes — update the invariant text in the same change.
4. **ToolLoopEngine** (one place, reused by chat and agent console): provider-agnostic loop
   with AgentRunner's semantics — max iterations, byte budget, per-tool error folding
   (`is_error`), event stream. AgentRunner can later be retired onto it.
5. **Chat UI**: tool-activity rows in `MessageBubble` (currently text-only); key `ForEach` by
   message identity, not offset.

### Phase 4 — Knowledge base + code search

1. **Migration `v4_knowledge_base`** (after `v3_enhancement_status`, `Database.swift:167-173`):
   `kb_sources` (kind: document | code_folder, plain path), `kb_documents` (rel_path, mtime,
   size for change detection), `kb_chunks_fts` (FTS5; **plain `unicode61 tokenchars '_'` for
   code** — porter stemming is wrong for identifiers), `kb_embeddings` (doc_id, chunk_index,
   vector BLOB — reuse `EmbeddingMath.pack`). DB stays a rebuildable index: `reindexAll()` from
   source files is the rebuild path, mirroring the sidecar invariant.
2. **`KnowledgeBaseStore` actor** (StorageKit), modeled on `SessionStore`: addSource /
   removeSource / reindexAll / search. Extraction: `String(contentsOf:)` for text/markdown/code
   (64 k cap like `ReadFileTool`), `PDFKit.PDFDocument.string` for PDF. Chunking ~6000 chars
   with overlap; embeddings optional/best-effort behind a toggle (FTS5 primary — same
   degradation philosophy as `indexSemantic`). Hook embedding spend into `costCapUSD`.
3. **Tools** (work in both the chat ToolLoopEngine and the existing Agent console):
   - `search_live_transcript` — LiveTranscriptHub units (timestamped; answers "what was said
     around minute 12") + FTS over finished sessions.
   - `search_knowledge_base` — kb_chunks FTS + cosine top-K merge (generalize the
     `LibraryState.semanticHits` logic out of the @MainActor view-model first).
   - `search_code` — argv-direct `rg` confined via `AgentToolGuard.requireInsideWorkspace`
     against the KB code-folder path (the BashTool pattern, proven).
   - `get_screen_frame(timestamp)` — existing `FrameExtractor` over the in-progress
     `screen.mp4` for vision answers.
4. **Settings**: `KnowledgeBaseTab` in `SettingsView` (tab bar is crowded — may need grouping);
   `Defaults` keys + `didSet` vars per the existing pattern; folder picker copied from
   `pickFolder()`.

## 5. Risks / open questions

1. **Privacy posture changes.** Live streaming sends every recorded second to Deepgram *during*
   the meeting (today batch upload happens once, after stop, behind the cost gate). The cost
   gate (`confirmCostOverage`) must move to recording start for streaming mode, and the
   "partial — leaves the machine" privacy note needs updating. WhisperKit users keep the local
   window engine — no regression.
2. **Latency vs cost of tool loops.** No streaming responses in AIKit (deferred to v1.1); a
   tool turn = N round-trips. Acceptable for v1; SSE streaming is the natural follow-up.
3. **Ollama/OpenRouter tool support is model-dependent** — needs capability detection and
   graceful degrade. The Ollama Anthropic-compat mode (§4 Phase 3a) removes the *protocol*
   uncertainty for Ollama (tool_use blocks are first-class on `/v1/messages`), but whether the
   *model* actually emits tool calls still varies — the degrade path stays.
4. **Live FTS visibility.** Indexing an in-progress session makes it appear in Library search
   mid-recording — decide whether that's a feature (probably yes) and ensure `clearAllSessions`
   gets its active-recording guard first (audit L-M6, still open).
5. **KB embedding spend** — per-chunk embeddings on a large code folder can be significant;
   default to FTS-only for code, embeddings opt-in per source.
6. **Design-doc process** — this document is a proposal; the canonical design doc needs a dated
   revision (new §, Decision Log entries) before implementation starts.

## 6. Suggested order of work

| Step | Scope | Unlocks |
|---|---|---|
| 1 | T-M3/T-M5/T-M6 fixes + fan-out sink + mic-only tagging | streaming stack production-ready |
| 2 | StreamingLiveSource + makeLiveProvider Deepgram branch + scrolling transcript UI | live transcript for default-provider users |
| 3 | Live persistence (TranscriptStore during recording + periodic FTS) | live retrieval; stop discarding live results |
| 4 | ChatState live context + live NSPanel + sendSnapshot fix | chat-during-recording (no tools yet) |
| 5 | AIKit tool types + provider serializers + ToolLoopEngine | tools in chat across all 4 providers |
| 5a | Ollama `.anthropicCompat` mode (shared Anthropic codec + base URL) | fully-local tool loop / agent via Ollama ≥ 0.14 |
| 6 | v4 migration + KnowledgeBaseStore + extractors + settings tab | knowledge base |
| 7 | Tools: search_live_transcript / search_knowledge_base / search_code / get_screen_frame | the full feature |

Steps 1–3 are pure enablement and independently shippable; 4 ships user value without tools;
5–7 complete the vision.
