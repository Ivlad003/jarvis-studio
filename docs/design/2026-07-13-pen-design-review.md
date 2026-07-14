# Design Review — `kosmo_notes_design.pen` vs. shipping app (0.0.2)

**Date:** 2026-07-13 (updated 2026-07-14 with review remarks)
**File reviewed:** `../kosmo_notes_design.pen` (Pencil)
**Compared against:** current-build screenshots — Menu-bar menu, Settings → Transcription, Library.
**Scope:** visual style, layout, and UX consistency. **Not** in scope: copy/labels, exact hotkey strings, feature-completeness of wording.

> **Framing note (per review remarks).** The design is treated as a **style and pattern system**, not a field-by-field build spec. Developers keep deliberate freedom: which fields exist, how each is configured, and which options a feature exposes are decided during that feature's planning and build — the design is not expected to enumerate every field. So where this review flags "undesigned" areas, the ask is a **pattern to reuse**, not a pixel spec for each control.

---

## 1. Summary

The `.pen` file is a well-structured, token-driven system: two-mode theming (light/dark), a coherent 20-component library, and disciplined reuse of instances across all nine Settings tabs. As a design *system* it is in good shape.

As a *snapshot of the current app*, it has drifted. It was drawn at an aspirational "1.0 / build 214" state, while the app runs "0.0.2". The three surfaces we can compare have each moved on in structure, not just content:

- **Menu bar** — custom card → native macOS vibrancy menu with SF Symbols.
- **Settings** — dense two-column @ 800 px → airy single-column in a wider window, plus two tabs (Knowledge, Logs) with no design pattern yet.
- **Library** — a richer app (waveforms, labeled actions with dropdowns, Share-to-S3) vs. a simplified design.

None of these are regressions in the design's *quality* — they are a **sync gap**. The cost is that the file no longer mirrors the app's structure, and a few same-type elements are now styled two different ways.

---

## 2. macOS feasibility & required OS version *(answers the review question)*

**Is there anything in the design that macOS cannot do? No.** Every screen maps onto native AppKit / SwiftUI building blocks:

- **Menu-bar panel, Camera Bubble** — a borderless floating `NSPanel`/`NSWindow` with a rounded mask (the bubble is just a circular window over an `AVCaptureVideoPreviewLayer`). Standard.
- **Agent Console, Chat, Session Picker sheet** — ordinary windows/sheets with list rows and an input bar. Standard.
- **Settings** — the inset-grouped card layout is exactly the macOS **System Settings** paradigm.
- **Palette** — the tokens are Apple's own semantic system colors (`primary #0A84FF` = systemBlue, `destructive #FF3B30` = systemRed, `success #30D158` = systemGreen, `warning #FF9F0A` = systemOrange). They translate 1:1 to native semantic colors and get free light/dark behavior.
- **Badges, toggles, segmented controls, steppers** — all have native equivalents.

**One deliberately non-native choice, not a blocker:** the type token is **Inter**, not SF Pro. Inter is perfectly shippable (bundle the font), but it's a conscious departure from the system font — worth a yes/no decision, not a technical constraint.

**Required macOS version to support the design:** conceptually **macOS 13 (Ventura)** — that's when System Settings adopted the inset-grouped look the design mirrors; SF Symbols and vibrancy predate it. Nothing in the file needs anything newer. The app already pins **macOS 14.0+**, which comfortably covers the entire design with headroom. **Conclusion: the design imposes no new OS floor — the current 14.0+ target is sufficient.**

---

## 3. The shift, surface by surface

### 3.1 Menu-bar menu
| | Design (`.pen`) | Shipping app |
|---|---|---|
| Surface | Opaque `$card` white card + custom outer drop-shadow | Native translucent **vibrancy** menu (blurs the wallpaper behind it) |
| Row icons | None | SF Symbols on **Settings** and **Quit** only |
| Width / padding | ~260 px, tight | Wider, native menu metrics |
| Structure | Version header, grouped items, dividers | Same grouping ✅ |

**Shift:** the design implies a hand-drawn menu; the app is a standard `NSStatusItem` menu. **Cost:** taken literally, the design points a developer toward custom-drawing a menu instead of using the native one — the wrong direction on macOS (loses vibrancy + free dark-mode/accessibility). Low remediation cost (redraw the mock as a vibrancy panel), worth fixing so the file stops pointing the wrong way.

### 3.2 Settings (Transcription tab as the reference)
| | Design | Shipping app |
|---|---|---|
| Body layout | **Two columns**, dense, window 800 px wide | **Single column** of grouped "inset" cards, wider window |
| Tab bar | Icon + label per tab; **active = neutral `$card` pill** | **Text-only** tabs; **active = blue (`primary`) filled pill** |
| Tab count | 9 (…Agent, Privacy) | 11 (adds **Knowledge** and **Logs**) |
| Helper text | Sparse (Section description slot) | Abundant inline guidance (e.g. the BlackHole setup steps, echo-cancellation notes) |
| Provider API keys | Merged into Transcription tab | Split out to the AI Providers tab |

**Shift:** this is the largest divergence. The design optimizes for compactness (two columns); the app optimizes for guided, one-thing-per-row readability (single column + lots of helper text). **Cost:**
- Two tabs (**Knowledge, Logs**) have no design pattern yet — acceptable given developer freedom (§ framing note), but they should at least inherit the shared Settings skeleton once their layout question is settled.
- The design's 800 px tab bar cannot hold 11 tabs without overflow/wrapping — the app already had to widen the window to fit them. The design's width is now stale.
- The two layout philosophies are unreconciled (see §5).

### 3.3 Library
See the dedicated gap list in **§8** — the design is materially behind the app here.

---

## 4. Design-system consistency audit (same-type elements)

Overall the component discipline is strong — `Button`, `Toggle`, `SegmentedControl`, `Section`, `TabBarItem`, `SessionRow`, `StatusBadge`, `PermissionRow` are reused as instances rather than re-drawn, so most same-type elements *are* consistent (secondary = transparent-fill + border everywhere; destructive = `$destructive` fill everywhere; the label-left / control-right row via `space_between` is uniform across Dictation, Hotkeys, Sharing, Markdown, Agent). Two real inconsistencies stand out:

1. **Permission-action affordance is styled two ways.** In **Privacy** the action is an **outline button** ("Open Settings" / "Request"); in **Onboarding** the same `PermissionRow` action is a **blue text link** ("Open Privacy Settings"). Same element, same job, two visual treatments. Pick one (recommend the outline button as the system default) and apply it in both places.

2. **Active-tab styling is internally fine but has diverged from the app.** The design's neutral card pill + icon is self-consistent across all nine Settings screens ✅ — but it no longer matches the app's blue text-only pill. Decide which is canonical and align the component once (it will propagate to all tabs).

Minor: Library detail actions are **icon-only** in the design but the app renders them as **labeled** controls — this is both a consistency and a discoverability issue (see §8).

No token-level problems found: spacing (`gap-xs…l`), radii, and the badge color set are used consistently.

---

## 5. Settings: "compact yet readable, with mindful CTA"

Measured against the stated goal, the two candidates sit on opposite sides and **neither is the target**:

- **Design (two-column, 800 px):** compact ✅, but readability is at risk — related controls are split across columns, and it will not scale to 11 tabs without overflow.
- **App (single-column, airy + heavy helper text):** very readable ✅, but not compact — long scroll, and the wall of setup text (BlackHole steps, echo-cancellation caveats) buries the actual controls.

**Recommendation — converge on one "compact-readable" system:**
- Single column (matches the app and macOS System Settings; survives 11+ tabs), **but** tighten section spacing. Keep only a one-line description per section inline; long explanations move to the affordance decided in §6.
- **CTA discipline:** the design already models this well — `Test Connection` next to API keys, a single filled primary per surface (`Continue`, `Add N sessions`), destructive in red. Preserve that. Ensure every section that *does* something has exactly one clear primary affordance and that read-only sections have none.

Net: keep the app's readable single-column skeleton, borrow the design's restraint and its clear single-CTA-per-section rule.

---

## 6. Field-level explanations — decide the affordance, not each field *(per review remarks)*

Whether any given field gets an explanation is **decided per field during feature work**, not mandated here — that stays with the developers. What the design *does* owe us is **one reusable pattern** for "this field needs a hint," so that when a field is deemed to need one, we already know how it looks and it stays consistent everywhere.

**Action for the design:** define a single explanation affordance and add it to the component library. Candidates:
- **Inline caption** under the control (what the app does today — readable, but adds vertical weight and can bury controls).
- **"ⓘ" info icon → popover/tooltip** next to the label (compact; hint on demand; fits the "compact yet readable" goal).
- **Disclosure ("Show details ▾")** for multi-step guidance like the BlackHole setup.

Recommendation: adopt the **"ⓘ" popover** as the default hint affordance, reserve the **disclosure** for genuinely long/multi-step help, and keep inline captions only for one-liners that are essential at a glance. Pick one, add it as a component, and the per-field yes/no becomes a trivial, consistent choice later.

---

## 7. Welcome / Onboarding screen

This screen is **not in the shipping app**; content will be reconsidered later. For now it only needs to *fit the global style*, and it mostly does: it uses `WindowChrome`, Inter, the shared `PermissionRow`, the type scale (20/700 title, 12 muted body), and a filled primary `Continue` CTA.

**One change to make it fit:** the permission action here is a blue **text link**, while the rest of the system uses an **outline button** for the identical action (§4, item 1). Swap it to the outline button so Onboarding reads as the same system. No other style work needed until the content is revisited.

---

## 8. Library — feature gaps vs. the shipping app  *(explicit action list)*

The design's Library is behind the built app. Add these to the backlog:

1. **Waveform thumbnails on session rows.** App rows show a mini-waveform per session; the design's `SessionRow` shows only mode-icon + date + duration. → add a waveform slot to `SessionRow`.
2. **Waveform audio scrubber in the detail pane.** App shows a real waveform player with time readouts; the design shows a plain progress bar (and only in the video/meeting variant). → design an audio-player variant of the detail pane, not just the `screen.mp4` video player.
3. **Labeled actions with dropdown menus.** App toolbar: **Copy ▾**, **Export ▾**, **Share to S3**, **Open in Finder**, **Delete** — labeled, with split-menu carets on Copy/Export. Design has **icon-only** buttons (upload / link / folder / trash) and no Copy, no Export menu. → redesign the actions row with labels + the two dropdowns.
4. **Explicit "Share to S3" action, including its disabled state.** App shows it as a distinct, sometimes-disabled control; design collapses sharing into a generic "upload"/"link" icon.
5. **±15 s transport with labels.** App shows labeled **−15s / +15s**; design uses unlabeled rotate icons.
6. **"Clear All" treatment.** Design uses a prominent filled-red toolbar button; the app demotes it to a subtle top-right trash **icon** button. Align to the quieter app treatment (destructive-but-not-shouting).

---

## 9. Coverage gaps (screens the design doesn't have)

Beyond Library, the file has **no active-recording / capture HUD** and **no Dictation floating panel**, and has no design pattern yet for the **Knowledge and Logs** Settings tabs. These are the next screens to add if the file is meant to track the app.

---

## 10. Priority

| # | Item | Type | Effort |
|---|---|---|---|
| P1 | Reconcile Settings layout on one compact-readable single-column system; give Knowledge + Logs the shared skeleton | Structure | M |
| P1 | Bring Library up to app parity (waveforms, labeled actions + dropdowns, audio scrubber) — §8 | Feature | M |
| P2 | Define the field-explanation affordance (recommend "ⓘ" popover) and add it as a component — §6 | System | S |
| P2 | Unify permission-action affordance (outline button) across Privacy + Onboarding | Consistency | S |
| P2 | Align tab-bar active state + icons to the app (or decide design is canonical) | Consistency | S |
| P3 | Redraw menu-bar mock as a native vibrancy menu with SF Symbols | Fidelity | S |
| P3 | Add active-recording HUD + Dictation panel | Coverage | M |
| — | Decide Inter vs. SF Pro as the type token | System | S |

**Bottom line:** the design system is healthy; the *sync with the app* is the debt. Close the Settings layout question first (it unblocks the two new tabs and the density goal), settle the explanation affordance, then bring Library to parity, then mop up the two same-type inconsistencies.

---

## For the CEO — review in one paragraph

The design file is in good health and, importantly, **nothing in it is technically risky or off-platform**: every screen is buildable with standard macOS tooling, the color system is Apple's own, and it requires no newer macOS than the version we already ship on — so there is no hidden platform cost. The real gap is **synchronization**: the file captures an aspirational "1.0" while the shipping app has moved ahead, most visibly in Settings (layout and two newer tabs) and in the Library (which is now richer in the app than in the design). None of this is a quality problem or rework — it's catch-up, and deliberately so, because we let engineering decide field-level detail during feature planning rather than pinning it in the design. The recommended next steps are small and sequenced: settle one Settings layout, define a single reusable "explain this field" affordance, and bring the Library mock up to what we already ship. Net: a solid foundation, a short and well-understood punch list, and no blockers to keeping design and product in step.
