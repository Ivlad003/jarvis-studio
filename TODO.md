# TODO — KosmoNotes engineering ownership

Owner: _(you)_ · Baselined on trunk **`main`** · Date: 2026-07-16
Product status: **v1.0 feature-complete, UNVERIFIED** (manual smoke pending before tagging)

> Canonical references: [design doc](docs/plans/2026-05-02-jarvis-note-design.md) (what/why),
> [CLAUDE.md](CLAUDE.md) (operating manual), [v1.0 checklist](docs/release/v1.0-checklist.md) (release gates).
> This file is the working backlog. Check items only when *verified*, not when coded.

> ✅ **Branch discipline (resolved 2026-07-13).** Trunk-based on `main` — `develop` was
> fast-forward-merged into `main` and retired along with all merged feature branches.
> Branch off `main` with short-lived `feat/`·`fix/`·`chore/` branches; merge back via PRs.

---

## 0. Onboarding — get it running on my machine

- [x] `brew install xcodegen` — **not currently installed**; required to generate the Xcode project
- [x] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — **green: 397 tests / 83 suites pass (~19s)**. ⚠️ First cold run flaked with 3 issues (timing-sensitive `CaptureSession`/audio-HAL tests); clean on rerun — watch for CI flakiness.
- [x] `xcodegen generate` → produces `KosmoNotes.xcodeproj` (gitignored)
- [x] `make install` → signed Release build to `/Applications/KosmoNotes.app` (needs an Apple Development cert in Keychain)
- [x] Confirm menu-bar icon (waveform) appears; no Dock icon (`LSUIElement`)
- [x] Add provider keys in Settings (Keychain-backed): Deepgram (transcription) + one LLM (Anthropic / OpenAI / OpenRouter / Ollama)
- [x] One end-to-end smoke: record 30s Meeting → live "You/Them" transcript → AI summary → Library → export

## 1. Learn the architecture (read-only onboarding)

The macOS app is a Swift package (7 library Kits + AudioDSP) + an App target (45 State files).

- [ ] **Read the design doc first** — every capture/transcription/encoding/IPC decision is recorded there
- [ ] Trace the capture pipeline: `CaptureKit` (AVAudioEngine mic + SCKit/Core Audio Tap system) → `AudioDSP` (Swift/Accelerate AEC) → `TranscriptionKit` (Deepgram WebSocket live + batch) → `StorageKit` (GRDB/FTS5 + embeddings) → `AIKit` (Provider protocol) → `SharingKit` (S3 Sig V4)
- [ ] Understand the App/State actors: `RecorderState`, `LiveTranscriptState` (dual-source You/Them merge), `ChatState` (tool-call agent), `LibraryState`
- [ ] Note the **AEC caveat**: echo cancellation is currently FORCED OFF (VoiceProcessingIO never delivered mic audio; see CLAUDE.md 2026-06-13 entry). Runtime AEC/dual-source paths need on-device verification (no audio in CI).
- [ ] Awareness only — **`windows/`** is a documented .NET 8 / WinUI 3 parity port, Phase 1 of 7 complete on macOS. Its own tracker is [windows/HANDOFF.md](windows/HANDOFF.md). Out of scope for this onboarding; no changes.

## 2. Documentation into shape

README and CLAUDE.md are current. Small cleanups + one reconciliation:

- [x] **Test-count drift.** README ("280 tests") and CLAUDE.md ("375 tests in 78 suites") both corrected to **`swift test` = 397 tests / 83 suites**, with a note that `make test-app` / `make test-all` add the App-target `AppTests/` on top. _(2026-07-16)_
- [ ] **Design-doc vs Windows port.** The design doc's stack invariants still say "Windows — out of scope / pure Swift," but a documented .NET port exists on develop. Add a dated design-doc revision (or §15 decision-log entry) acknowledging the parallel workstream — per the repo's own "surface, don't silently accommodate" rule. _(Decision to record, not code to change.)_
- [ ] Skim `AGENTS.md` and the `docs/superpowers/specs/` additions for anything stale.
- [x] ~~`main`'s README/CLAUDE.md are badly stale — decide whether `main` gets retired/merged~~ **Resolved: `develop` merged into `main` and retired (2026-07-13); `main` is the trunk. See §4.**

## 3. Verification — close the "UNVERIFIED" gap

Nothing here is a code task; it's proving what's coded works on real hardware.

- [ ] Run the manual smoke matrix: [docs/release/v1.0-checklist.md](docs/release/v1.0-checklist.md) (3 OS × core flows)
- [ ] AC-9b dictation latency: [docs/manual-smoke/2026-05-02-ac9b-dictation-latency-procedure.md](docs/manual-smoke/2026-05-02-ac9b-dictation-latency-procedure.md) (median ≤1.5s)
- [ ] **On-device verify** the two paths CI can't reach: AEC (currently off) and dual-source You/Them live transcription
- [ ] Recovery path: `kill -9` mid-record → relaunch → Recover dialog finalizes the session
- [ ] TCC prompts fire (Microphone, Screen Recording, Accessibility); note the macOS 15+/26 `-3801` screen-capture quirk in CLAUDE.md
- [ ] One Sharing backend end-to-end (AWS / R2 / MinIO)
- [ ] Bundle size gate: zip ≤ 8 MB, unzipped ≤ 15 MB (AC-16 / CI)

## 4. Branch hygiene (owner decision)

- [x] ~~Decide `main`'s fate~~ **Done (2026-07-13): `develop` fast-forward-merged into `main` and retired; trunk-based development on `main`. A fresh clone now lands on the current trunk.**

## 5. Agentic review & architecture analysis (optional, on request)

- [ ] Build the code-review knowledge graph: `/code-review-graph:build-graph`
- [ ] Security review: hand-rolled AWS Sig V4 in `Sources/SharingKit/`, Keychain usage, the tool-call agent's transcript/screen access
- [ ] Concurrency review: Swift 6 strict-concurrency across the actor-based capture/transcription pipeline

## 6. Release path (blocked on §3)

- [ ] Fill both smoke matrices + AC-9b table in the v1.0 checklist
- [ ] `xcodegen generate` → Release build → `ditto` zip → verify size gates → `git tag -a v1.0.0`

---

### Open questions
- Final product name: repo/app = **KosmoNotes**, design doc = **Jarvis Note**. Pick one canonical name.
- Is the Windows port in or out of the v1.0 story? (Currently a separate track; the macOS app ships first.)
