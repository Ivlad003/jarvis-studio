# Architecture and Invariants

## Source of Truth

`docs/plans/2026-05-02-jarvis-note-design.md` is the spec, not a draft. Use it for capture APIs, transcription providers, encoding format, IPC shape, file layout, and dependency lifecycle.

If implementation diverges from the design doc, treat that as a decision. Do not rewrite the spec quietly.

## Stack Invariants

- Pure Swift, SwiftUI, AppKit, and native frameworks only.
- No Rust, FFI, Tauri, iced, Electron, or webview in v1.
- Bundle target remains small: single `.app`, roughly 5-15 MB excluding downloaded WhisperKit models.
- Swift concurrency is the default concurrency model.
- SQLite is an index, not the source of truth.

## Deployment Target

macOS 14.0+ is the actual deployment target. `Package.swift`, `project.yml`, and `LSMinimumSystemVersion` all pin 14.0. The app will not run on macOS 12.3-13.x without substantial API replacement.

Within macOS 14:

- Core Audio Tap is macOS 14.4+.
- ScreenCaptureKit audio fallback covers macOS 14.0-14.3.

## Data Model

Sessions live under:

```text
~/Library/Application Support/KosmoNotes/recordings/<sid>/
```

Sidecars are canonical:

- `audio.m4a`
- `transcript.jsonl`
- `summary.md`
- `actions.json`
- `screen.mp4` when Audio + Screen is enabled

`sessions.sqlite` provides FTS5, filtering, optional embeddings, and should be rebuildable from sidecars.

## Providers

- Transcription is hybrid: cloud by default, WhisperKit opt-in for local transcription.
- WhisperKit models are downloaded to Application Support, never bundled.
- LLM providers use the shared provider abstraction for Anthropic, OpenAI, OpenRouter, and Ollama.
- Ollama is REST-only. Do not bundle inference.

## Sharing and Secrets

- Sharing uses raw presigned URLs for audio/markdown bundles. There is no hosted viewer page.
- Store secrets in macOS Keychain. Config files may store Keychain account references only.

## Pivot Discipline

The old Jarvis Studio Rust workspace lives on branch `archive/jarvis-studio-rust`. Do not check it out unless the user explicitly asks for historical reference.

The Swift/cloud-transcription direction is settled for v1. A Rust core, webview frontend, or another stack pivot requires a separate design pass.
