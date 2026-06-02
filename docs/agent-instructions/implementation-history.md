# Implementation Notes and History

## Recent Fixes

2026-05-25 fixes:

- Mic audio is mixed into `screen.mp4` before session finalization.
- Screen-recording fallback warnings are surfaced in the menu.
- Startup screen-permission checks use `CGPreflightScreenCaptureAccess()`.
- `SCSampleTaskBag` removes completed tasks and closes against late callbacks after drain.
- Mic mute writes silence instead of dropping buffers, preserving recording timelines.
- ScreenCaptureKit audio conversion allocates `AudioBufferList` storage by CoreMedia's requested byte count.
- `RecorderLiveTee` feeds accumulated sample time into `LiveTranscriptEngine`.

## Recording Pipeline

- `Sources/CaptureKit/AudioEngine.swift` captures microphone PCM.
- `Sources/CaptureKit/ScreenRecorder.swift` writes `screen.mp4` with screen video and optional SCKit audio.
- `Sources/CaptureKit/ScreenAudioMixer.swift` merges standalone mic audio into `screen.mp4`.
- `App/State/RecorderState.swift` waits for screen-audio mixing before marking a recording complete.
- `App/State/RecorderLiveTee.swift` tees PCM into a temporary CAF file for live transcription.

Audio must remain the primary artifact. Screen capture failure is an audio-only fallback, not a recording failure.

## Encoding

The original design mentioned Opus. Implementation uses AAC in `.m4a`.

Reasons:

- Native Apple playback support is reliable.
- Recovery can concatenate AAC segments through `AVMutableComposition` and `AVAssetExportSession`.
- No bundled `ffmpeg` is needed.
- The current macOS 14 target removes the old 12.3 compatibility rationale, but AAC remains the chosen v1 format.

If Opus is revisited, treat it as a new design decision.

## Feature History

Major v1 additions:

- Audio + Screen recording mode with `screen.mp4`.
- Voice Note mode with prompt templates.
- Global hotkeys through `KeyboardShortcuts`.
- Cost-cap enforcement modal.
- OpenRouter provider.
- Optional embedding semantic search.
- S3-compatible sharing.
- Per-process Core Audio Tap on macOS 14.4+.
- Waveform thumbnails.
- Sleep assertion during active recording.
- Termination hook that flushes active recordings.
- Deepgram live transcription with reconnect support.
- WhisperKit local transcription as an opt-in provider.

## Legacy Context

The project began as Jarvis Studio, a Rust/Tauri/iced screen recorder. That code is preserved on `archive/jarvis-studio-rust`.

Files retained on `main` for context:

- `docs/plans/2026-05-01-jarvis-studio-design.md`
- `docs/plans/2026-05-01-vibe-tests.md`
- `docs/plans/2026-05-01-chrome-extension-analysis-uk.md`

These files describe history, not current implementation direction.
