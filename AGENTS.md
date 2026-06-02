# AGENTS.md

Operational guidance for Codex when working in this repository.

## Project

KosmoNotes, formerly Jarvis Note, is a native SwiftUI/AppKit macOS menu-bar app for recording meetings or voice notes, transcribing them, summarizing them, indexing them, chatting over them, exporting them, and sharing selected artifacts.

When the user says "the project" or "implementation", assume they mean KosmoNotes/Jarvis Note unless they explicitly say Jarvis Studio or the archive.

## Current Status

v1.0 is feature-complete but still needs manual smoke before release. Last local verification on 2026-05-25:

- `make test`: 293 package tests in 60 suites passed.
- `xcodebuild ... -only-testing:KosmoNotesTests`: 15 app tests passed.

## Canonical Sources

- Architecture/spec: [Jarvis Note design doc](docs/plans/2026-05-02-jarvis-note-design.md)
- Implementation plan: [.omc plan](.omc/plans/2026-05-02-jarvis-note-v1-implementation.md)
- Release checklist: [v1.0 checklist](docs/release/v1.0-checklist.md)

Read the design doc before answering "how do I implement X" or changing architecture. Do not silently edit the design doc to match implementation drift; add a dated revision only after the decision is explicit.

## Quick Commands

```sh
xcodegen generate
make test
make install
```

Use `make install` for installed app builds. It builds, signs with the Apple Development certificate, removes the stale app bundle, and copies to `/Applications`.

## Load-Bearing Rules

- Pure Swift/SwiftUI/AppKit. No Rust, Tauri, Electron, webview, or FFI for v1.
- Actual deployment target is macOS 14.0+. Do not revive 12.3-13.x fallback code without a separate design pass.
- Filesystem sidecars are source of truth; SQLite is a rebuildable index.
- Secrets live in macOS Keychain. Do not store plaintext API keys in JSON.
- Screen recording is optional and configurable; audio capture must continue when screen capture fails.
- Use `CGPreflightScreenCaptureAccess()` for startup screen-permission checks. Do not use `SCShareableContent.excludingDesktopWindows` as a TCC probe.

## Detailed Instructions

- [Architecture and invariants](docs/agent-instructions/architecture.md)
- [Build, signing, permissions, and tests](docs/agent-instructions/build-permissions-tests.md)
- [Implementation notes and project history](docs/agent-instructions/implementation-history.md)
