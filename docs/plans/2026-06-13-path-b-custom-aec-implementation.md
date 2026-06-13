# Path B — Custom Acoustic Echo Canceller (pure Swift + Accelerate/vDSP)

**Date:** 2026-06-13 · **Status:** implementation plan / design pass — needs a §15 Decision Log
entry in `docs/plans/2026-05-02-jarvis-note-design.md` before integration (US-6) lands.

> This is the plan, not the code. Stages 1–5 (the DSP core) are **CI-verifiable offline**; only the
> capture wiring (US-6) needs on-device verification. Author: distilled from the Path B research
> spec (2026-06-13) + grounded in the current KosmoNotes capture/transcription pipeline.

---

## 1. Why this exists

Recording a meeting through **laptop speakers** lets the remote participant's voice ("Them") leave
the speakers and re-enter the **microphone** ("You"), so the remote voice is captured twice — once
clean (system tap) and once as echo in the mic. The dedicated echo canceller Apple ships
(VoiceProcessingIO) is **disabled** in this app: it is a duplex unit that needs an output render
path our input-tap-only engine doesn't have, so enabling it makes the mic tap never fire (zero
captured audio, confirmed on-device 2026-06-13) and wiring the output path throws an uncatchable
CoreAudio `-10868`. See the `NOTE` in `Sources/CaptureKit/AudioEngine.swift`
(`applyVoiceProcessingIfNeeded`) and the `fix(capture): force echo cancellation off` commit.

**The architectural gift:** we already capture a *pristine* copy of "Them" — the system-audio tap
(`source: .system` on the `LivePCMSink`). Every other AEC has to derive its far-end reference from a
noisy loopback; we have it clean. That makes a **reference-based adaptive canceller** the natural,
native, dependency-free fix.

### Relationship to what already shipped this session
- **You/Them dual-source live transcript** (`LiveTranscriptState.merging(you:them:)`, two
  `RecorderLiveTee` engines): "Them" is already captured cleanly from the system tap, so AEC is no
  longer required for *attribution* — only for cleaning the mic's **"You"** track of bleed.
- **AEC forced off + toggle disabled** (`AppSettings.echoCancellationEnabled = false`,
  `SettingsView` toggle `.disabled(true)`): this plan replaces that dead VPIO toggle with a working
  DSP-based one.

## 2. Hard constraints (verified against the repo)

| Constraint | Source | Consequence |
|---|---|---|
| **macOS 14.0 floor** (hard — binary won't launch below) | `Package.swift` `.macOS(.v14)`; `project.yml` `MACOSX_DEPLOYMENT_TARGET=14.0`, `LSMinimumSystemVersion` mirrors it | The DSP core needs **no `@available` gates** — Accelerate/vDSP predate 14.0 by a decade. Only the *capture* layer is gated (`CoreAudioTap` `@available(macOS 14.4, *)` + SCKit fallback), which is already handled. |
| **Native only, no FFI** | CLAUDE.md stack invariant: "Pure Swift / SwiftUI / AppKit. No Rust, no FFI… Native frameworks only. Bundle 5–15 MB." | No WebRTC APM / SpeexDSP. Use `Accelerate` (vDSP) + `AVAudioConverter`. Target **< 1 MB** added. |
| **Real-time audio thread hygiene** | AudioEngine tap closure is "real-time-safe: no actor hops, no allocations" (`AudioEngine.installTap`) | Preallocate all buffers + `vDSP_create_fftsetup` once; no locks/allocations in the per-block path. |
| **Filesystem sidecars are source of truth** | CLAUDE.md invariant | Cleaned mic only changes what we *write* (`audio.m4a`, live "You" tee); SQLite/transcript rebuild semantics unchanged. |

## 3. Signal model (what we compute)

- `x[n]` = far-end reference = the clean "Them" system tap.
- `d[n]` = mic capture = `s[n]` (your real speech) + `echo[n]` + noise.
- `echo[n]` = `x` convolved with the unknown speaker→room→mic impulse response `h`.

Train an adaptive FIR `w` (length `N`) to estimate `h`:

```
ŷ[n] = wᵀ · x_window     // predicted echo
e[n] = d[n] − ŷ[n]       // cleaned "You" output AND the adaptation error
```

When `w ≈ h`: `ŷ ≈ echo`, so `e ≈ s` (your voice alone). `e[n]` is both the output and the learning
signal — that duality is the whole trick.

**Run at 16 kHz mono.** Echo energy is < 8 kHz, the transcription pipeline wants 16 kHz anyway, and
48→16 kHz cuts taps 3×. Resample with `AVAudioConverter` (native).

## 4. Where it slots into the codebase

```
 mic (AudioEngine, 48k F32 mono) ─┐
                                   ├─► [EchoCancellationProcessor] ─► cleaned "You" 16k/48k
 system tap (SCStream/CoreAudioTap)┘        (CaptureKit actor)            │
   via LivePCMSink(source:.system)                                       ├─► SegmentWriter (audio.m4a)
   — already carries hostTime + source tag                              └─► live "You" RecorderLiveTee
```

### Module layout
- **New SwiftPM target `Sources/AudioDSP/`** — *pure Accelerate, zero AVFoundation*, so it unit-tests
  trivially and stays reusable:
  - `GCCPHAT.swift` — bulk-delay estimator (Stage 1)
  - `NLMSCanceller.swift` — time-domain adaptive filter (Stage 2)
  - `GeigelDTD.swift` — double-talk detector (Stage 3)
  - `ERLE.swift` — `10·log10(‖d‖²/‖e‖²)` measurement helper (testing)
  - *(later)* `MDFCanceller.swift` (Stage 4), `ResidualSuppressor.swift` (Stage 5)
  - Add `AudioDSP` to `Package.swift` `targets` + a `AudioDSPTests` test target.
- **`Sources/CaptureKit/EchoCancellationProcessor.swift`** (new) — the integration glue:
  - Owns two lock-free ring buffers (mic, system) tagged with `hostTime`.
  - Resamples each to 16 kHz mono via a preallocated `AVAudioConverter`.
  - Coarse-aligns by `hostTime`; fine-aligns via `GCCPHAT`; runs `NLMSCanceller` + `GeigelDTD`;
    emits cleaned mic blocks.
  - Self-calibrating **bypass** (Stage 6): when predicted-echo energy is negligible vs `‖d‖²`
    (headphones / no acoustic loop), pass the mic straight through.
- **Wiring** (`CaptureSession`): when DSP-AEC is enabled, the cleaned mic replaces the raw mic feed
  into the SegmentWriter mic source (`enqueueMicBuffer` path, ~`CaptureSession.swift:980`) and the
  live "You" tee. The system tap path is unchanged.

### Why this path is SAFE (unlike VPIO)
It is **pure post-capture signal processing** — it never calls `setVoiceProcessingEnabled`, never
touches the AVAudioEngine output graph, so it **cannot** reintroduce the dead-mic / `-10868` failure.
Worst case it is a passthrough. Therefore, once the offline core hits its ERLE bar, it is safe to
ship enabled-by-default with the self-calibrating bypass.

### Stream alignment & RT hygiene (cross-cutting)
- mic and system arrive in **separate callbacks** → push both into preallocated ring buffers tagged
  with `hostTime` (the `LivePCMSink.receive(_:at:source:)` already provides `hostTime: UInt64`).
- Pull time-aligned blocks by `hostTime` for *coarse* alignment; GCC-PHAT handles the *fine*
  sub-block delay on top.
- Zero allocations / no locks in the per-block path; `vDSP_create_fftsetup` once up front.

## 5. Staged implementation (condensed; full derivations in the spec)

> Reference skeletons below are starting points — validate offline before trusting.

### Stage 1 — Bulk delay alignment (GCC-PHAT)
Estimate the speaker→mic bulk delay `D` (20–80 ms, route-dependent) once and advance the reference by
`D`, so the adaptive filter only models the residual room tail (~64–128 ms). FFT both signals, form
`conj(X)·D`, PHAT-normalize each bin to unit magnitude, IFFT, peak lag = delay. `fftSize ≥ 4096` at
16 kHz (covers ±128 ms); estimate over 1–2 s of active double-channel audio; re-run on route change.
*(Skeleton: `estimateDelayGCCPHAT` — mind the vDSP packed real-FFT Nyquist convention.)*

### Stage 2 — NLMS adaptive filter (the core — ship first)
O(N)/sample, unconditionally stable for `0 < μ < 2`. Update: `w += (μ / (‖x‖² + δ)) · e · x_window`.
Efficiency trick: **double-length reference ring** so the dot product reads a contiguous window (one
`vDSP_dotpr`) and `‖x‖²` updates in O(1). Coefficient update in one `vDSP_vsma`. Start: `N=2048`
(~128 ms), `μ=0.3`, `δ=1e-6`; converges in 1–2 s of far-end speech. *(Skeleton: `NLMSCanceller`.)*

### Stage 3 — Double-talk detection (Geigel; freeze, don't diverge)
When both speak, near-end `s[n]` looks like a huge error and yanks `w` off the true path. Detect via
Geigel (`|d| ≥ T·max|x|`over the window, `T≈2`), **freeze adaptation** (`adapt=false`) while still
filtering with frozen coefficients, with a ~40 ms hold. `max|x|` via `vDSP_maxmgv`. If it still
drifts, upgrade to normalized-cross-correlation DTD before adding filter length. *(Skeleton:
`GeigelDTD`.)*

### Stage 4 — MDF (frequency-domain partitioned) — DEFERRED
Migrate the hot path to overlap-save partitioned-block frequency-domain filtering (block `B`=128/256,
FFT=`2B`, `K=ceil(N/B)` partitions, `Y=Σ W_k·X_k`). O(log B) amortized, one-block latency. **Stop
point:** if time-domain NLMS CPU is already negligible at the chosen tail on Apple Silicon, skip.
Port the *algorithm* from Speex `mdf.c` to Swift+vDSP — **do not link the C.**

### Stage 5 — Residual suppressor (Wiener-type STFT) — DEFERRED
Class-D laptop amps add nonlinear distortion the linear filter can't model. A per-bin Wiener gain
`G[k]=Ŝ/(Ŝ+R̂esidual)` over the linear output, + comfort noise. **Stop point:** if linear ERLE > ~25–30
dB and residual is inaudible *in the transcript*, skip — typical for a notes product.

### Stage 6 — Bypass when there's no echo path (cheap; do early)
Self-calibrating: monitor predicted-echo energy `‖ŷ‖²` (or `e`↔`x` coherence) vs `‖d‖²`; if
negligible → headphones/no loop → passthrough. Optionally *bias* (not replace) with
`kAudioDevicePropertyTransportType`. Matches the confirmed finding: bleed appears only on speaker
output.

## 6. vDSP primitive map
FIR `y=w·x`: `vDSP_dotpr` (time) / `vDSP_zvmul`+accum (freq) · NLMS update: `vDSP_vsma` · max-mag:
`vDSP_maxmgv`/`vDSP_maxmgvi` · FFT: `vDSP_create_fftsetup`/`vDSP_fft_zrip`/`vDSP_destroy_fftsetup` ·
split↔interleaved: `vDSP_ctoz`/`vDSP_ztoc` · spectral mult: `vDSP_zvmul` · power: `vDSP_zvmags` ·
scalar mult: `vDSP_vsmul` · biquad: `vDSP_biquad`. Block 128–256 (~8–16 ms @ 16 kHz).

## 7. Testing strategy (this is the point — most of it is CI-verifiable)

The DSP core is **pure functions on Float arrays** → `make test` (SwiftPM `AudioDSPTests`) covers it
with **no device, no mic**:
- **GCC-PHAT:** feed `ref` + a known-delayed copy → recovered delay within ±1 sample across several
  delays and `fftSize`s.
- **NLMS ERLE:** synthesize `echo` = `ref` convolved with a known FIR (+ optional small noise), feed
  `mic = echo`, assert steady-state **ERLE ≥ 20 dB** within N samples; assert no divergence on
  silence (energy guard) and stability for `μ ∈ [0.1, 0.5]`.
- **Geigel:** inject near-end speech during far-end → assert `adapt` freezes and `w` stays put;
  assert it resumes after the hold.
- **Processor:** synthetic two-stream scenario (delayed/scaled/filtered `ref` as mic echo + a distinct
  near-end signal) → ERLE on the echo-only segments, near-end preserved.
- **Bypass:** no-echo input → output ≈ input (passthrough), processing bypassed.

**Device-only (US-6, user-verified):** real meeting on speakers → inspect `audio.m4a` and the live
"You" transcript for reduced bleed; route-change re-estimation; CPU headroom. Offline-validate on
recorded tap+mic pairs first.

## 8. Executable PRD (stories + acceptance criteria)

> Right-sized so each is one iteration. Order = foundational first. Stages 4/5 are explicitly
> deferred behind their stop points. Mirror this into `prd.json` to drive a `/oh-my-claudecode:ralph`
> or `/implement` run.

- **US-1 — AudioDSP target + GCC-PHAT.** `Sources/AudioDSP` target added to `Package.swift` with an
  `AudioDSPTests` target. `estimateDelayGCCPHAT` implemented.
  *AC:* (a) `make test` builds the new target; (b) test recovers a known delay (e.g. 37, 512, 1500
  samples) within ±1 at `fftSize=4096`; (c) no `@available` gates in AudioDSP; (d) 0 lsp diagnostics.
- **US-2 — NLMS canceller + ERLE harness.** `NLMSCanceller` + `ERLE` helper.
  *AC:* (a) synthetic echo (known FIR) → steady-state **ERLE ≥ 20 dB**; (b) stable (no NaN/Inf, bounded
  `w`) for `μ ∈ {0.1,0.3,0.5}` and on all-silence input; (c) one `vDSP_dotpr` + one `vDSP_vsma` per
  sample (no per-sample loops over taps); (d) `make test` green.
- **US-3 — Geigel DTD.** `GeigelDTD` wired so double-talk freezes adaptation.
  *AC:* (a) test shows `w` frozen during injected near-end-over-far-end and resumes after hold;
  (b) ERLE on echo-only segments unchanged vs US-2; (c) `make test` green.
- **US-4 — EchoCancellationProcessor (offline).** Resample (48→16k `AVAudioConverter`), ring-buffer
  hostTime alignment, orchestrate delay-align → NLMS → DTD; expose a block `process` API.
  *AC:* (a) synthetic two-stream test: echo suppressed (ERLE ≥ 18 dB on echo-only) while a distinct
  near-end signal is preserved (correlation with clean near-end ≥ 0.9); (b) zero allocations in the
  steady-state block path (preallocated buffers + one fftsetup); (c) `make test` green.
- **US-5 — Self-calibrating bypass (Stage 6).**
  *AC:* (a) no-echo input → output ≈ input (sample MSE ≤ 1e-6) and the adaptive path is bypassed;
  (b) echo input → not bypassed; (c) `make test` green.
- **US-6 — Capture integration + setting (device-verified).** Wire cleaned mic into SegmentWriter mic
  source + live "You" tee; replace the disabled VPIO toggle with a DSP-AEC toggle (re-enable
  `SettingsView`); re-estimate delay on route change; Decision Log entry added.
  *AC:* (a) `make test` + `make test-app` green; (b) `AppSettings` exposes the DSP-AEC toggle (no
  longer forced-off); (c) `docs/plans/2026-05-02-jarvis-note-design.md §15` gains a dated Decision Log
  entry; (d) **manual (user):** speaker recording shows reduced "Them" bleed in `audio.m4a` and the
  live "You" transcript, headphones path bypasses cleanly, no recording regression.
- **US-7 (deferred) — MDF.** Only if US-4 CPU is non-negligible on target hardware.
- **US-8 (deferred) — Residual suppressor.** Only if residual echo is audible in the transcript after
  US-1–6.

**Ship line:** US-1 → US-5 + US-6 is a complete, native, dependency-free AEC. US-7/US-8 are
optimizations behind explicit stop points.

## 9. Risks & decisions
- **Stream time-alignment is the hardest real-world part** — mic and system come from different
  capture paths; rely on `hostTime` coarse + GCC-PHAT fine, and re-estimate on route change. Offline
  validation on real recorded pairs de-risks it before live wiring.
- **Device/room dependence** — all numbers (μ, N, thresholds) are starting points; the offline ERLE
  tests lock in correctness, on-device tuning locks in quality.
- **Bundle size** — Accelerate is a system framework; net add is the Swift source (< 1 MB). No
  invariant deviation, unlike WebRTC/Speex (which would need an explicit §15 deviation + size review).
- **Decision Log:** US-6 must add a dated §15 entry recording "custom vDSP AEC replaces VPIO; VPIO
  retired for capture" — load-bearing per repo rules.

## 10. References
Haykin, *Adaptive Filter Theory* (NLMS, stability) · Benesty/Gänsler/Morgan, *Advances in Network and
Acoustic Echo Cancellation* (DTD, freq-domain AEC) · Knapp & Carter 1976 (GCC-PHAT) · Soo & Pang 1990
(MDF) · Speex `mdf.c` (cleanest open MDF to port — study, don't link).
