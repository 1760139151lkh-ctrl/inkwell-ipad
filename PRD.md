# PRD — Notability-style iPad Notes App (working name: **Inkwell**)

**Owner:** Pat Simmons · **Date:** 2026-09-24 · **Status:** Phase 1 spec, ready for build (rev 2: live transcription, cloud backup, own recording view, screens review)
**Audience:** the coding agent that builds this. Read the whole doc before writing code.

---

## 0. TL;DR for the build agent

Build a **native iPad app** (SwiftUI + PencilKit + AVFoundation) that works like Notability:

1. A **library** of notes grouped into color-coded **Subjects**.
2. A **note editor** where you write with **Apple Pencil** on paper-style pages (lined, grid, dot, blank).
3. **Audio recording while you write.** Every pen stroke is time-stamped against the recording.
4. **Synced playback:** during playback, ink not yet written at the current audio time is faded and darkens as the audio reaches it. **Tap any handwriting to jump the audio to the moment it was written.**

5. **Live transcription** while recording, using Apple's on-device speech engine (§7.6).
6. **Cloud backup** to Pat's Neon Postgres, through a small API (§8.3).

Item 4 is the hardest part and the whole point of the app. Everything else is a standard notes app.

**Two places where you use your own judgment and then show Pat:**
- **The recording view (§6.12).** Pat doesn't like how Notability handles viewing recordings. Design our own version and present it for review.
- **The screens review (§12, M3.5).** Before polishing, show Pat every screen of the app. He will react, and the design changes from there.

**Keep it simple.** Match Notability's feature set and layout; do **not** add extra features, settings, onboarding, animations, badges, or "helpful" UI that isn't in this doc. When unsure, leave it out.

---

## 1. Phases (context only; build Phase 1)

| Phase | Goal | In this doc |
|---|---|---|
| **1 — Clone** | Functional Notability clone on iPad: library, pencil notes, recording, synced playback, **live transcription**, **cloud backup**. Notability's layout, except the recording view, which is our own (§6.12). Ends with Pat reviewing all app screens. | **Full spec (§2–§12)** |
| 2 — Own UI + AI | Our own visual design across the app (driven by Pat's reactions to the Phase 1 screens); AI features on top of the transcripts. | Hooks only (§10) |
| 3 — Agent handoff | One button, "Hand off to agent": sends handwriting + transcript + timing to a coding agent (Claude Code / Codex), which works out the repo and the tasks. | Hooks only (§10) |

Phase 1 **must** store data so that Phases 2–3 need no migration (§10). That is the only forward-looking work allowed in Phase 1.

---

## 2. Product principles

1. **Pencil-first.** Apple Pencil draws; fingers scroll and zoom. Writing latency must feel like PencilKit/Notes.app, with no lag.
2. **Recording is never lost.** Audio writes to disk continuously. A crash or backgrounding mid-meeting must never lose more than a few seconds.
3. **Notability parity, not more.** If Notability doesn't do it, we don't do it (see §3 for which Notability features we skip).
4. **Local-first, backed up.** The iPad is the source of truth and works fully offline. The cloud is a backup copy (§8.3), not a live dependency. There's no login screen: this is Pat's personal app, and one API token in the Keychain is enough.

---

## 3. Scope

### P0 — must ship in Phase 1
- Library: sidebar (All Notes, Subjects with colors), note list, create/rename/delete/move notes, create/rename/recolor/delete subjects.
- Note editor: vertically scrolling letter-size pages, auto-append a new page when you write near the bottom, paper styles (Plain, Rule, Grid, Dot) + 6 paper colors + portrait/landscape via the Paper sheet (§6.11).
- Tools: **Pen, Pencil, Highlighter, Eraser, Lasso**, Undo/Redo. Each ink tool has 3 favorite colors + a color picker, and 3 size presets.
- Audio: Record / Stop, multiple recordings per note, playback bar (play/pause, −10s/+10s, scrubber, elapsed/total, speed).
- **Recording view (§6.12)**, our own design: open a note's recordings and see and play them, with the transcript alongside.
- **Synced replay** (fade unwritten ink, darken in time) and **tap handwriting to seek**.
- Autosave everything. Page navigator ("1 / 6" with up/down).
- Search notes by title.

### P1 — ship in Phase 1 if P0 is solid
- Text boxes (typed text on the page), time-stamped like strokes.
- Insert photo (PhotosPicker) as a movable, resizable image on the page.
- Import PDF as a note (each PDF page becomes a page background you can write over).
- Export note as PDF (share sheet).
- Content manager side panel: page thumbnails, bookmark a page, jump to a page.
- Recording list: rename/delete a recording.
- Dividers (collapsible groups of subjects in the sidebar).
- Recently Deleted (30-day restore).
- Single Page view mode (Seamless is P0).
- **Live transcription** while recording + transcript saved per recording, searchable (§7.6). *This is "P1" only in build order. The recording view is designed around it, so it must land in Phase 1.*
- **Cloud backup** to Pat's Neon project: Postgres + Object Storage + Functions (§8.3), including restore on a fresh install.

### Explicitly OUT (do not build)
Gallery/community templates · template marketplace · audio EQ "Tuning" · "Voice Boost" · laser pointer · tape tool · stickers · math conversion · handwriting-to-text · real-time multi-device sync (backup/restore only) · accounts/login screens · sharing/collaboration · subscriptions/paywalls · onboarding/tutorials · "update required"/backup banners · presentation mode · Apple Watch · widgets · Mac Catalyst.

---

## 4. Platform & stack

| Choice | Decision |
|---|---|
| Device | iPad only (portrait + landscape). iPhone not supported in Phase 1. |
| Min OS | **iPadOS 26** (Xcode 26.3 is installed). Required for `SpeechAnalyzer`/`SpeechTranscriber` live transcription (§7.6). *Pat is checking his iPad's version and may need to update.* |
| UI | SwiftUI; `UIViewRepresentable` wrapper around `PKCanvasView`. |
| Ink | **PencilKit** (`PKCanvasView`, `PKDrawing`, `PKInkingTool`, `PKEraserTool`, `PKLassoTool`). Do **not** use the system `PKToolPicker`; build our own toolbar. |
| Audio | **AVAudioEngine** input tap → `AVAudioFile` (AAC `.m4a`, 44.1 kHz mono, ~64 kbps). Use the engine instead of `AVAudioRecorder`, because the same tap also feeds `SpeechAnalyzer` (§7.6). Playback: `AVAudioPlayer` per recording, or `AVQueuePlayer` for one combined timeline. |
| Persistence | **SwiftData** for metadata, plus files on disk for drawings, audio, and images (§8). |
| Transcription | Apple **Speech** framework: `SpeechAnalyzer` + `SpeechTranscriber` (iPadOS 26). On-device, free, offline once the model is downloaded (§7.6). |
| Backup | **Neon only**, one project (`floral-meadow-08263294`, branch `production`): Postgres (metadata + transcripts) + Object Storage bucket (audio, drawings, images) + a Neon Function as the API (§8.3). No Vercel. |
| Architecture | Plain SwiftUI + `@Observable` view models. No third-party Swift dependencies. The backup API is a separate small TypeScript project in `server/`. |

---

## 5. Information architecture

```
App
├── Library (NavigationSplitView, 3 columns)
│   ├── Sidebar: Search · All Notes · Subjects (+ Dividers) · Settings
│   ├── Note list: notes in the selected subject
│   └── Detail: Note editor
└── Note editor
    ├── Title bar (editable title)
    ├── Main toolbar (floating, centered) + contextual sub-bar
    ├── Canvas (pages, vertical scroll)
    ├── Page navigator (bottom-right)
    └── Content manager (right panel, toggle)
```

On iPad, the note editor is the detail column. A **Library toggle** button (top-left of the editor) collapses the sidebar and note list so the note goes full-screen for writing. This matches Notability's Mac/iPad layout.

---

## 6. Screen specs

Layout below comes from the Notability Mac app (captured 2026-09-24). Pat confirmed it matches the iPad app. Measurements are in points and approximate. Match the proportions and feel, not the exact pixels.

### 6.1 Visual language (Phase 1 = Notability-like)
- **Chrome:** dark. Sidebar ≈ `#1E2229`, note list ≈ `#15181D`, toolbar pill ≈ `#15181D` with a 1pt `#2E333B` border, primary accent blue ≈ `#4A90E2` (the "New" button and the active tool highlight).
- **Paper:** white page on the dark editor background. The page fills the editor width (inset ~0–16pt) and scrolls vertically.
- **Type:** SF Pro for UI. A **serif display face** (e.g. New York) for the subject title at the top of the note list ("AI Advisory") and the note title in the editor ("Note Jan 22, 2025").
- **Subject colors:** a palette of ~8 swatches (seen: light green, dark green, teal, crimson, orange-red, plus blue, purple, yellow).

### 6.2 Library — Sidebar (≈228pt wide)
```
┌──────────────────────────┐
│ ⚙︎                        │  Settings (gear), top-left
│ [🔍 Search      ] Cancel │  searches note titles across all subjects
│ 📝 Notes                  │  = All Notes
│ ─────────────────────────│
│ Subjects             ＋   │  + = new subject (name + color)
│ ● AI Advisory        74  │  selected row: lighter bg, rounded 8pt, count shown
│ ● Clearhaven Consulting  │
│ ● AI Workshops           │
│ ● Internal               │
│ ● Client Discovery       │
└──────────────────────────┘
```
- Row: 10pt color dot, name (15pt medium), note count (only on the selected row, as in Notability).
- Long-press a subject: **Rename · Change Color · Delete** (confirm; the notes inside move to "Unfiled").
- Drag to reorder subjects. (P1) Dividers are collapsible headers that group subjects.
- Drop a note from the note list onto a subject to move it.
- *Out:* Gallery row and the promo banners at the bottom.

### 6.3 Library — Note list (≈195pt wide)
```
┌───────────────────────────┐
│            (…)  [＋ New]  │  … = sort/select menu; New = primary blue pill
│ AI Advisory               │  serif, 22pt bold — the selected subject's name
│ ┌────┐ Note Jul 3, 2025   │
│ │thumb│ Jul 6, 2025  🎙    │  mic glyph = note has ≥1 recording
│ └────┘                    │
│ ┌────┐ Epic Bill Regr…    │  title truncates with an ellipsis
│ │    │ Feb 22, 2025  🎙    │
└───────────────────────────┘
```
- Row ≈ 66pt tall: 54×54 thumbnail of page 1 (white, rounded 6pt), title (14pt semibold, 1 line), modified date (12pt, secondary), mic glyph when the note has audio.
- Selected row gets a subtle highlight.
- **＋ New** is a plain button, not a menu (verified in Notability). It creates a note in the selected subject, titled `Note <MMM d, yyyy>`, with the default paper, and opens it immediately at the top of the list.
- **… menu:** *Sort by:* Date Modified (default) / Date Created / Title · *Select* (multi-select → Move / Delete) · *Import PDF…* (P1).
- Swipe a row left: **Delete** (confirm). Long-press a row: **Rename · Move to… · Duplicate · Export PDF (P1) · Delete**.

### 6.4 Note editor
```
┌──────────────────────────────────────────────────────────────────────┐
│ [▤]        ┌──────────────────────────────────────────┐   [↶][↷] [⋯][▯]│
│            │ Tt ⬚ 🖼 │ ✒︎ ✎ ▰ ⌫ │ 🎙 ▶︎ │ ✋            │                │  main toolbar
│            └──────────────────────────────────────────┘                │
│            ┌──────────────────────────────────────────┐                │
│            │  (contextual sub-bar: tool options,      │                │  sub-bar
│            │   recording bar, or playback bar)        │                │
│            └──────────────────────────────────────────┘                │
│ Note Jan 22, 2025   ← serif title, tap to rename                       │
│ ┌──────────────────────────────────────────────────────────────────┐   │
│ │                     page 1 (white, paper style)                  │   │
│ │   handwriting…                                                    │   │
│ └──────────────────────────────────────────────────────────────────┘   │
│ ┌──────────────── page 2 … ───────────────────────────────────────┐ ┌─┐│
│                                                                     │^││
│                                                                     │1││ page navigator
│                                                                     │6││
│                                                                     │v││
└──────────────────────────────────────────────────────────────────────┴─┘
```
- **[▤] Library toggle** (top-left): collapses or expands the sidebar and note list.
- **Title:** serif, 20pt, above page 1. Tap to edit inline.
- **[⋯] Note menu** (top-right), modeled on Notability's (*Quick share PDF · Share options · Template settings · View settings › · Info ›*):
  - *Share PDF* (P1): share sheet with the note rendered to PDF.
  - *Paper…*: opens the Paper sheet (§6.11).
  - *View* ›: **Seamless** (continuous vertical scroll, default) / **Single Page** (paged horizontally, one page at a time).
  - *Rename* · *Move to…* · *Delete Note*.
  - *Out:* Night Mode, Info.
- **[▯] Content manager** toggle (P1), §6.8.
- **Undo/Redo**: buttons top-right. Also two-finger tap = undo and three-finger tap = redo (iPad convention).
- **Empty-note state:** a blank first page with a quick paper picker centered at the bottom of the page: `Rule | Grid | Dot | Import` (Import = P1, PDF). It disappears after the first stroke.

### 6.5 Main toolbar (floating pill, centered, ~40pt tall, icons 18pt)
Left to right, as in Notability:

| # | Tool | PencilKit / impl | Sub-bar when selected (tap the active tool again to toggle it) |
|---|---|---|---|
| 1 | **Text** (Tt) — P1 | Custom text-box overlay | Font size S/M/L, bold, color (3 favorites) |
| 2 | **Lasso** | `PKLassoTool` (freeform) | *Freeform* (Phase 1). *Boxed* is out. After a selection: Cut / Copy / Delete / Color menu. |
| 3 | **Media** — P1 | PhotosPicker → image element | none (opens the picker) |
| 4 | **Pen** | `PKInkingTool(.pen)` | 3 favorite colors (default black, blue, red) + "+" (UIColorPicker) · 3 widths (thin/med/thick) |
| 5 | **Pencil** | `PKInkingTool(.pencil)` | same layout as Pen (default graphite, blue, red) |
| 6 | **Highlighter** | `PKInkingTool(.marker)` | 3 favorites (default yellow, pink, green) + "+" · 3 widths |
| 7 | **Eraser** | `PKEraserTool` | *Stroke* (`.vector`) / *Partial* (`.bitmap`) · 3 sizes |
| — | divider | | |
| 8 | **Record** 🎙 | §7 | While recording, the sub-bar shows the **recording bar** |
| 9 | **Play** ▶︎ (only if the note has recordings) | §7 | Shows the **playback bar** |
| — | divider | | |
| 10 | **Navigate** ✋ | canvas `drawingPolicy`/tool off | none. In this mode, taps on ink seek the audio (§7.4). |

- The active tool shows a blue-tinted icon (the highlighter also shows a swatch underline in its current color).
- Tool, color, and width selections persist per tool across notes (store them in `UserDefaults`).
- **Apple Pencil double-tap** (`UIPencilInteraction`): toggles between the current tool and the eraser (system preference respected).
- **Finger input** never draws (`drawingPolicy = .pencilOnly`). Fingers scroll, pinch-zoom (0.75×–3×), and tap. A Settings toggle "Draw with finger" is the only exception, for use in the Simulator.

*Deviation from Notability:* Notability swaps the mic for a ▶︎ once a note has audio and hides "Start Recording" on a second toolbar page. We show **Record and Play side by side** because recording is our core use case. This is the only intentional layout change.

### 6.6 Recording bar (sub-bar while recording) — Notability baseline; §6.12 may replace it
```
┌──────────────────────────────────────────────┐
│ ● REC   12:48        ▁▃▅▂▆▃ (level)    [■ Stop]│
└──────────────────────────────────────────────┘
```
- Red pulsing dot, elapsed time (mm:ss or h:mm:ss), a small live input-level meter, and a Stop button.
- The Record toolbar button turns red while recording. Tapping it also stops.
- Leaving the note or backgrounding the app **keeps recording** (background audio mode). A small red "REC 12:48" pill appears in the Library while any note is recording. Tap it to return to that note.

### 6.7 Playback bar (sub-bar during playback)
```
┌──────────────────────────────────────────────────────────┐
│ ⟲10  ⟳10  ●━━━━━━━━━━━━┃━━━━━━━━━━━━  0:19 / 21:38   (⋯) │
└──────────────────────────────────────────────────────────┘
```
- −10s / +10s, a scrubber with a **tick at each recording boundary** (a note with 2 recordings = 1 tick), elapsed and total time.
- ▶︎/⏸ lives in the main toolbar (item 9), as in Notability.
- **(⋯) Playback popover:**
  - **Recordings** list: ▶︎ icon · "Recording 1" · `12m 49s · 1/22/25, 5:02 PM`. *Edit* → rename / delete (P1).
  - **Playback speed:** 0.5× · 0.75× · 1× · 1.25× · 1.5× · 2× (pitch-corrected: `AVAudioUnitTimePitch` or `AVAudioPlayer.enableRate`).
  - *(Phase 2)* "Show transcript on play" toggle. Leave a placeholder row out of Phase 1. Don't add it.
  - *Out:* Tuning (EQ), Voice Boost.

### 6.8 Content manager — right panel (P1, ≈190pt)
- **Pages only.** Transcripts live in the recording view (§6.12), not here.
- Filter: *All Pages* / *Bookmarked*.
- Vertical page thumbnails, numbered, with a bookmark ribbon toggle in each thumbnail's corner. Tap a thumbnail to scroll to that page.
- *Select* mode: delete pages (confirm). Reorder is out of scope.

### 6.9 Page navigator
- A floating vertical capsule at the bottom-right of the canvas: `^` / `current` / `total` / `v`. Up and down jump one page. Tapping the number opens a "Go to page" field.

### 6.10 Settings (sheet from the sidebar gear) — keep it tiny
Notability's Settings is a two-pane sheet (left: section list, right: detail; "Close" top-right). Sections observed: About, Subscription, Help · Auto-Backup, Manage Accounts, iCloud, Recently Deleted · Themes, Document, Typing, Handwriting, Audio, Locked Subjects · Text-to-Speech. **We keep only:**
- **Document:** default note title (text, default "Note") + *Include date* (on) / *Include time* (off), with a live example "Note Sep 24, 2026". Default paper (opens the Paper sheet). Default view: Seamless / Single Page.
- **Pencil:** Draw with finger (off by default).
- **Audio:** Recording quality, Standard (64 kbps) / High (128 kbps). **Live transcription** on/off (default on), matching Notability's "Audio Transcription" toggle. Transcription language (default English; picker limited to `SpeechTranscriber.supportedLocales`) and the model download status/button (§7.6).
- **Backup:** status ("Last backup 2 min ago" / "Backing up 3 notes…" / error), a *Back Up Now* button, a *Restore from Backup* button (fresh install only; confirm first), and the API URL + token fields (token saved to the Keychain).
- **Recently Deleted** (P1): deleted notes are kept 30 days; restore or delete permanently.
- **About:** version, storage used.

Nothing else.

### 6.11 Paper sheet (Notability calls it "Templates")
Full-screen sheet, *Cancel* (left) / *Apply* (right), title "Paper".
- **Style:** four large thumbnails in a row: **Plain · Rule · Grid · Dot**. The selected one has a blue border and a "CURRENT" label. Each non-plain style has a ⋮ with spacing Narrow / Medium / Wide.
- **Color:** a row of 6 circles: White, Off-white, Cream, Black, Light blue-gray, Tan.
- **Orientation:** Portrait / Landscape toggle (top-right of the section).
- Size is fixed to US Letter in Phase 1 (Notability has a size picker; skip it).
- *Out:* "From the Gallery" templates, planners, worksheets, notepads, "My Templates".
- Applies to the whole note. The empty-page footer (`Rule | Grid | Dot | Import | Templates`) is a shortcut: the first three apply instantly, *Templates* opens this sheet.

### 6.12 Recording view — OUR design, not Notability's (use your judgment, then show Pat)

**Why:** Pat doesn't like Notability's recording UX. In Notability:
- recording hides behind a toolbar icon that turns into ▶︎ once audio exists, with "Start Recording" moved to a second toolbar page;
- the list of recordings is buried in a small "⋯" popover under the playback bar, mixed in with EQ settings;
- the transcript is a separate tab in the page-thumbnail side panel.

Viewing a recording is awkward, and it gets worse once we're live-transcribing.

**What Pat asked for:** a clear, second way to **tap a recording and actually view it**. The same place should show the **live transcript while recording**. §6.6/§6.7 (recording bar, playback bar) are the Notability baseline. You may change or replace them as part of this design.

**Your brief:**
- Design **one** recording view, using your best judgment. Keep it as simple as the rest of the app, with no extras.
- It must cover these states: *no recordings yet* · *recording live* (elapsed time, level, the transcript streaming in with volatile text dimmed and final text solid) · *recorded, idle* (list of the note's recordings: name, date/time, duration) · *playing* (the transcript follows the playhead and highlights the current line).
- Interactions it must support: start/stop recording · open a recording · play/pause/seek · **tap a transcript line to seek there** (the same seek as tapping ink, §7.4) · rename/delete a recording.
- The ink replay (§7.4) keeps working while this view is open. The view must not hide the page you're writing on during a live recording. For example, use a side panel or a collapsible sheet that leaves the canvas visible.
- One reasonable starting point (not a requirement): a right-side **Recordings panel** that replaces Notability's popover and Transcripts tab. It has the recordings list at the top and the selected recording's transcript below, with the playback controls pinned at the bottom.
- **Deliverable:** build it for real, working with real recordings and live transcription (not a static mock), and include it in the screens review (§12 M3.5). Pat will react and iterate with you. Keep the view in its own files (`RecordingPanel*.swift`) so it's easy to redesign.

---

## 7. Core feature — audio-synced notes (read carefully)

### 7.1 What Notability does (observed)
- A note can have **several recordings** (e.g. *Recording 1, 12m49s* and *Recording 2, 8m48s*). Playback treats them as **one continuous timeline** (21:38), with a tick at the boundary.
- On **Play**, strokes written **before** any recording stay at full opacity. Strokes written **during** recordings appear **faded (~25% opacity)** until the playhead reaches the moment each was written, then turn fully dark. You watch your notes "re-write themselves" in sync with the audio.
- With the navigate/hand tool, **tapping a handwritten word seeks the audio** to when that word was written and starts playback.
- Scrubbing moves the fade boundary live.

### 7.2 The timing model
PencilKit gives us what we need:
- `PKStroke.path.creationDate: Date` is the wall-clock time the stroke began.
- `PKStrokePoint.timeOffset: TimeInterval` is each point's offset from `creationDate`.

We record each recording's wall-clock anchor:

```
Recording.startedAt   // Date the first audio sample was captured (see 7.3)
Recording.duration    // seconds
Recording.order       // 0,1,2… in the note timeline
timelineOffset(r)     = Σ duration of recordings with order < r.order
```

Map a stroke to note-timeline time:

```swift
func timelineTime(of stroke: PKStroke, in recordings: [Recording]) -> TimeInterval? {
    let t = stroke.path.creationDate
    guard let r = recordings.first(where: { t >= $0.startedAt && t <= $0.startedAt + $0.duration })
    else { return nil }               // written outside any recording → "untimed", always full opacity
    return timelineOffset(r) + t.timeIntervalSince(r.startedAt)
}
```

- Text boxes and images store their own `createdAt: Date` and use the same function.
- **Keep an index.** On note open and after each edit, build a sorted array `[(time, strokeIndex)]` of timed strokes. The playback renderer reads it; it's rebuilt on stroke add, remove, or erase.
- Don't store per-stroke times separately. Derive them from `creationDate`, which keeps one source of truth. **Verify** (acceptance test M3-5) that `creationDate` survives lasso-move, copy/paste, and partial-erase splitting. PencilKit strokes have no user-info field, so if partial erase resets `creationDate` on the split pieces, fall back to recovering the time: match the new piece to the pre-erase stroke by renderBounds overlap and inherit its creationDate. Build this with a before/after diff in the eraser's `canvasViewDrawingDidChange`. **Test this first, before building the replay UI.**

### 7.3 Recording implementation
- **How Pat records (confirmed):** the call plays out of his **Mac Studio speakers**, and the iPad's built-in mic picks up the room: the other people from the speakers, plus Pat's own voice. This is exactly how he uses Notability today. So we capture the room mic. There's no system-audio capture and no call integration.
- `AVAudioSession`: category `.playAndRecord`, mode `.default`, options `[.allowBluetoothHFP, .defaultToSpeaker]`. **Do not** enable voice processing on the input node (`setVoiceProcessingEnabled`): its echo cancellation and noise suppression can treat speaker audio as echo and remove the other people's voices. Test with a real call on the Mac speakers ~1m away, and compare `.default` against `.measurement` mode for loudness and transcription accuracy. Pick the better one.
- Handle interruptions (phone call → stop the current recording segment cleanly; do not auto-resume) and route changes.
- `AVAudioEngine.inputNode.installTap` → (a) write buffers to an `AVAudioFile` (AAC), (b) compute the RMS for the level meter, (c) convert and yield them to the transcriber (§7.6). One tap, three consumers. Never block the tap thread.
- **Anchor accuracy:** set `startedAt` from the first buffer's `AVAudioTime`, converted to wall clock (`Date()` minus the latency implied by `hostTime`). Target error < 50 ms. A simple first pass, `startedAt = Date()` in the first tap callback minus the buffer duration, is acceptable if measured < 100 ms.
- Each Record→Stop creates **one new `Recording`** row and file. Pausing is out of scope; stop and record again.
- **Crash safety:** AVAudioFile writes incrementally. On launch, find orphaned recording files with no `duration`, compute the duration from the file, and attach them to their note.
- Info.plist: `NSMicrophoneUsageDescription`, `UIBackgroundModes = [audio]`.

### 7.4 Playback & replay rendering
- **Player:** build one `AVMutableComposition` from all recording files, in order, and play it with `AVPlayer` (gives one seekable timeline and rate control). Add a periodic time observer at ~30 Hz.
- **Replay mode** is on while the playback bar is visible and the playhead has been started or scrubbed.
  - Render timed strokes with `time > playhead` at **25% alpha**, and everything else normally.
  - **Implementation:** keep the editable `PKCanvasView`. In replay mode, overlay a second, non-interactive `PKCanvasView` (or swap the drawing) whose `PKDrawing` is a copy with the future strokes' ink colors at alpha 0.25. **Rebuild only when the playhead crosses a stroke boundary** (binary search in the index). Don't rebuild every frame. For long notes, rebuild only the strokes whose state changed and reassign the drawing. Target a rebuild under 16 ms for 5,000 strokes. If that's missed, move to a Core Graphics/Metal renderer (out of Phase 1 unless needed).
  - The user can keep writing during playback. New strokes are untimed (no recording running) or timed to the current recording.
- **Tap-to-seek:** in Navigate mode (or any mode while replay is on, with a **finger** tap), hit-test the strokes at the tap point: `renderBounds.insetBy(-8)` contains the point, then the minimum distance to the path's interpolated points is < 12pt. Among the hits, pick the stroke with the **latest** creationDate. Seek to `max(0, time − 1.0s)` (1s pre-roll so you hear the lead-in) and play. Untimed strokes: no-op.
- **Auto-scroll (nice-to-have, P1):** while playing, if the stroke being "written" at the playhead is off-screen, scroll it into view. Suspend auto-scroll for 5s after any user scroll.

### 7.5 Acceptance criteria (the core loop)
1. Record 60s while writing "one" at ~5s, "two" at ~20s, "three" at ~40s. Stop. Press Play: all three words are faded, and each turns dark within ±150 ms of its moment.
2. Tapping "three" jumps playback to ~39s.
3. Scrubbing to 25s shows "one" and "two" dark, "three" faded.
4. Two recordings in one note → the total time is the sum, there's a tick at the boundary, and words from recording 2 map correctly.
5. Ink written before the first recording is never faded.
6. Force-quit mid-recording → relaunch → the recording exists with ≥ (elapsed − 5s) of audio, and replay sync still works.
7. Backgrounding the app for 2 minutes mid-recording captures those 2 minutes.

### 7.6 Live transcription (Apple on-device speech)
**Engine:** the **`SpeechAnalyzer`** framework, new in iPadOS 26 (WWDC25, "Bring advanced speech-to-text to your app with SpeechAnalyzer"). It's the same engine behind Apple's new system transcription in Notes and Voice Memos. It runs **on-device**: free, private, offline after a one-time model download, built for long-form audio (meetings), with low latency. It replaces the old `SFSpeechRecognizer`. Don't use `SFSpeechRecognizer`, and don't use a cloud STT service in Phase 1.

**Setup:**
```swift
import Speech

let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],        // live partial text
    attributeOptions: [.audioTimeRange])         // per-word timestamps
let analyzer = SpeechAnalyzer(modules: [transcriber])

// 1. Model: system-shared asset, may need a download the first time.
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await req.downloadAndInstall()           // idempotent; show progress in Settings → Audio
}
// 2. Format: the analyzer does NOT convert audio. Mismatched buffers produce silence and throw no error.
let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
// 3. Input: AsyncStream<AnalyzerInput>, fed from the same AVAudioEngine tap as the file writer.
let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
try await analyzer.start(inputSequence: inputSequence)
//    in the tap: convert buffer (AVAudioConverter, primeMethod = .none) → inputBuilder.yield(AnalyzerInput(buffer: converted))
// 4. Results
for try await result in transcriber.results {
    // result.text: AttributedString (runs carry .audioTimeRange), result.range: CMTimeRange, result.isFinal
}
// 5. On Stop: inputBuilder.finish(); try await analyzer.finalizeAndFinishThroughEndOfInput()
```

**Rules:**
- **Volatile vs final:** show volatile text dimmed, and replace it when the final result for that range arrives. **Persist only finals.** Write finals to `transcript/<recordingID>.json` as they arrive (append/flush), so a crash keeps the transcript up to that point.
- **Timestamps:** `result.range` and the per-run `audioTimeRange` are relative to the start of the analyzer input. We start the analyzer on the same first buffer as the file, so they're **recording-relative**, the same frame as §7.2. Note-timeline time = `timelineOffset(recording) + t`. Verify drift over a 60-minute recording is < 0.5s. If there is drift, re-anchor using the buffer sample counts.
- **Availability:** check `SpeechTranscriber.isAvailable` and `supportedLocales`. If it isn't available on Pat's iPad, fall back to **`DictationTranscriber`** (same `SpeechAnalyzer` API, lower quality), and say so in Settings → Audio.
- **Backfill:** if live transcription fails or is interrupted, or transcription was off while recording, offer **"Transcribe"** on that recording. It runs `analyzer.analyzeSequence(from: AVAudioFile)` over the saved file. Same JSON output.
- **Search:** the library search also matches transcript text (plain substring over the JSON's text, cached in a `Recording.transcriptText` field). Results show the note, and tapping one opens the recording view at that line.

**Known limitations (tell Pat, don't solve in Phase 1):**
- **No speaker labels** (no diarization). Everything from the Mac speakers is one mixed source anyway.
- **No custom vocabulary** in the iPadOS 26.0 API. Names and jargon ("Clearhaven", client names) will sometimes come out wrong.
- Accuracy depends on how loudly and clearly the Mac speakers reach the iPad mic.
- Upgrade path, if needed later: re-transcribe the saved audio with a cloud model that supports diarization and custom vocabulary, on the server (§8.3), after the call. Not now.

**Transcript JSON** (`transcript/<recordingID>.json`):
```json
{ "recordingId": "…", "locale": "en-US", "engine": "SpeechTranscriber",
  "segments": [ { "start": 12.40, "end": 17.85, "text": "We should move the launch to Friday.",
                  "words": [ { "start": 12.40, "end": 12.61, "text": "We" } ] } ] }
```

**Acceptance:** (1) during a recording, words appear within ~1s of being spoken on the Mac speakers; (2) after Stop, the JSON exists with finals only, and segment times line up with the audio within ±300 ms; (3) tapping a transcript line in the recording view seeks there; (4) force-quit mid-recording keeps every final segment written up to that point.

---

## 8. Data model & storage

### 8.1 SwiftData models
```swift
@Model final class Subject {
  @Attribute(.unique) var id: UUID
  var name: String
  var colorHex: String
  var sortIndex: Int
  var divider: Divider?            // P1
  @Relationship(deleteRule: .nullify, inverse: \Note.subject) var notes: [Note]
}

@Model final class Divider { var id: UUID; var name: String; var sortIndex: Int; var isCollapsed: Bool } // P1

@Model final class Note {
  @Attribute(.unique) var id: UUID
  var title: String
  var subject: Subject?            // nil = Unfiled
  var createdAt: Date
  var modifiedAt: Date
  var paperStyle: PaperStyle       // .blank .ruled .grid .dot
  var paperColor: PaperColor       // .white .cream .dark
  var pageCount: Int
  var bookmarkedPages: [Int]       // P1
  var pdfBackgroundFile: String?   // P1: relative path to imported PDF
  @Relationship(deleteRule: .cascade) var recordings: [Recording]
  @Relationship(deleteRule: .cascade) var elements: [PageElement]  // text boxes, images (P1)
  var deletedAt: Date?             // Recently Deleted (P1)
  var lastBackedUpAt: Date?        // backup (8.3): dirty when modifiedAt > lastBackedUpAt
  // Drawing is NOT stored here (large). See 8.2.
}

@Model final class Recording {
  @Attribute(.unique) var id: UUID
  var note: Note?
  var order: Int
  var name: String                 // "Recording 1"
  var startedAt: Date              // wall-clock anchor (7.3)
  var duration: Double             // 0 while recording; finalized on stop/recovery
  var fileName: String             // "<id>.m4a"
  var transcriptStatus: TranscriptStatus  // .none .live .complete .failed
  var transcriptText: String?      // flattened final text, for search (full detail lives in the sidecar JSON, 8.2)
}

@Model final class PageElement {   // P1
  @Attribute(.unique) var id: UUID
  var kind: ElementKind            // .text .image
  var frame: CGRect                // in canvas coordinates
  var createdAt: Date              // for replay timing
  var text: String?                // .text (plain or AttributedString data)
  var imageFileName: String?       // .image
}
```

### 8.2 Files (Application Support, one folder per note)
```
Notes/<noteID>/
  drawing.pkdrawing        // PKDrawing.dataRepresentation(); written debounced 1s after the last change + on background
  thumb.png                // page-1 thumbnail, 200px, regenerated on save
  audio/<recordingID>.m4a
  images/<elementID>.jpg   // P1
  background.pdf           // P1 import
  transcript/<recordingID>.json   // final segments + word timestamps (7.6)
```
- **Canvas geometry:** one `PKCanvasView` per note, with a fixed page width of 612pt (US Letter) scaled to fit the screen width, pages of 792pt stacked vertically with a 16pt visual gap drawn in the background layer. The strokes live in one `PKDrawing` in canvas coordinates. `pageIndex = floor(y / (792 + 16))`. This keeps "one note = one drawing", which makes export and the Phase 3 handoff simple.
- **Auto-append a page** when a stroke ends within the bottom 20% of the last page.
- **Autosave:** no Save button. Debounced writes, plus a flush on `scenePhase == .background` and on leaving the note.

### 8.3 Cloud backup — all on Neon (Postgres + Object Storage + Functions)
**Decision:** Pat created a Neon project for this. Neon now provides the whole backend in one place, so we use nothing else:
- **Postgres**: metadata, transcripts, stroke timing.
- **Object Storage**: a private bucket for large files. It's S3-compatible and supports presigned URLs.
- **Functions**: our small API. It runs Node 24 at a public HTTPS URL per branch, with `DATABASE_URL` and the bucket credentials added automatically.

The whole setup is declared in one `neon.ts` file and shipped with `neon deploy`. The iPad **never connects to Postgres directly**, because a database connection string can't safely ship inside an app.

```
iPad app ──HTTPS + Bearer token──▶  Neon Function "api"  ──▶  Neon Postgres        (metadata, transcripts, stroke timing)
    │                                    └─ issues presigned URLs ─┐
    └──────────── PUT/GET large files directly ────────────────────▶  Neon bucket "uploads" (audio .m4a, .pkdrawing, images, PDFs, thumbs)
```

**Project setup — DONE (2026-09-24).** Current state:
- The repo is linked (`.neon`) to project `floral-meadow-08263294` ("Notability Opus 5.5", `aws-us-east-2`), branch `production`.
- `neon.ts` is at the repo root, using the GA top-level keys: `auth: true`, bucket `uploads` (private), function `api` → `./server/api.ts`.
- `server/api.ts` is still Neon's "Hello from Neon Functions" placeholder. **Replace it with the backup API.** It's deployed and returns 200 at `https://br-lucky-resonance-b44aj51v-api.compute.c-6.us-east-2.aws.neon.tech/`. That URL is also in `.env` as `NEON_FUNCTION_API_BASE_URL`.
- Postgres 18 is reachable. The `uploads` bucket exists. Neon Auth is enabled but unused.
- `.env` (gitignored, written by `neon link`/`neon deploy`) holds: `NEON_API_KEY` (an **org-scoped** key), `DATABASE_URL`, `DATABASE_URL_UNPOOLED`, `NEON_BRANCH`, `NEON_AUTH_BASE_URL`, `NEON_AUTH_JWKS_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `NEON_FUNCTION_API_BASE_URL`.
- **CLI:** `neon` 6.1.0. Authenticate non-interactively with `NEON_API_KEY` from `.env`. Don't `source .env`: `DATABASE_URL` contains `&`. Extract the one line instead, e.g. `export NEON_API_KEY="$(grep '^NEON_API_KEY=' .env | cut -d= -f2-)"`. The stored browser session is expired, and there's no need for `neon auth`.
- Neon's agent skills are installed in `.claude/skills` (`neon-functions`, `neon-object-storage`, `neon-postgres`, …). **Read `neon-functions` and `neon-object-storage` before writing the API.**
- *Not done:* `neon mcp`. It needs a personal key or browser login, because org keys can't mint keys. It isn't needed for the build.
- Deploy loop: edit `server/api.ts` → `neon config plan` → `neon deploy`. Test locally with the Functions dev server (`neon functions --help`).

- **Why a Function with a bearer token, instead of Neon Auth + the Data API:** those are built for multi-user apps with row-level security. This is a one-person app, so a small API with a single token is simpler. The same Function becomes the **Phase 3 handoff endpoint**. `auth: true` stays in the config, so we can switch to real login later without re-provisioning.
- **Why files aren't in Postgres:** audio is ~29 MB/hour. Files go in the bucket; Neon stores only their keys, sizes, and SHA-256 hashes.
- **Secrets:**
  - `NEON_API_KEY` is in the root `.env`.
  - `neon deploy` writes the bucket/DB credentials to `.env.local`.
  - `INKWELL_API_TOKEN` is set as a Function environment variable.
  - All of these are gitignored and live only in Neon/`.env*`. **Never put them in the iOS app or in git, and never print them.**
  - The iPad stores only the Function URL + `INKWELL_API_TOKEN`, in the Keychain, entered once in Settings → Backup.

**Model — one-way backup, not sync.** The iPad is the source of truth. The server holds a copy. There are no merge conflicts, because there's only one writer.
- A note is **dirty** when `modifiedAt > lastBackedUpAt`. A backup runs 30s after the last edit, on app background, and on *Back Up Now*. It uploads the dirty notes' metadata + changed files (compared by SHA-256), then sets `lastBackedUpAt`.
- **Files go straight from the iPad to the bucket** using presigned PUT URLs from the Function. **Audio uploads use a background `URLSession`**, so a 2-hour recording finishes uploading after the app is closed. Upload only **after** a recording stops. Never stream mid-recording.
- **Deletes** propagate as tombstones (`deleted_at`). The server keeps them 30 days.
- **Restore:** on a fresh install, *Restore from Backup* pulls every note and downloads its files using presigned GET URLs. That's the only direction data flows down in Phase 1.
- Offline: queue it and retry with backoff. Backup must never block or slow down writing or recording.

**Neon schema (`server/db/schema.sql`):**
```sql
create table subjects   (id uuid primary key, name text not null, color_hex text not null, sort_index int not null,
                         divider_id uuid, updated_at timestamptz not null, deleted_at timestamptz);
create table notes      (id uuid primary key, subject_id uuid references subjects(id), title text not null,
                         paper jsonb not null, page_count int not null, created_at timestamptz not null,
                         modified_at timestamptz not null, deleted_at timestamptz,
                         drawing_key text, drawing_sha256 text, thumb_key text);
create table recordings (id uuid primary key, note_id uuid not null references notes(id), ord int not null, name text not null,
                         started_at timestamptz not null, duration_s double precision not null,
                         audio_key text, audio_sha256 text, deleted_at timestamptz);
create table transcripts(recording_id uuid primary key references recordings(id), locale text, engine text,
                         segments jsonb not null, full_text text not null,
                         search tsvector generated always as (to_tsvector('english', full_text)) stored);
create index on transcripts using gin (search);
create table strokes_index (note_id uuid primary key references notes(id),   -- for Phase 3: per-stroke time + bounds, no ink
                         strokes jsonb not null);   -- [{i, created_at, t_note, page, bbox:[x,y,w,h]}]
create table elements   (id uuid primary key, note_id uuid not null references notes(id), kind text not null,
                         frame jsonb not null, created_at timestamptz not null, text text, file_key text, deleted_at timestamptz);
```

**API (the Neon Function `api`, source `server/api.ts`: a single `fetch`-style handler with a tiny router; every route requires `Authorization: Bearer $INKWELL_API_TOKEN`):**
| Method | Path | Purpose |
|---|---|---|
| `PUT` | `/api/notes/:id` | Upsert note metadata + subjects + recordings + elements + transcripts + strokes_index (one JSON body) |
| `POST` | `/api/uploads` | Returns presigned PUT URLs for the bucket (key = `notes/<noteId>/<path>`), so large files go straight from the iPad to the bucket, not through the Function |
| `POST` | `/api/downloads` | Returns presigned GET URLs for restore |
| `DELETE` | `/api/notes/:id` | Tombstone |
| `GET` | `/api/notes?since=` | List for restore (metadata + file URLs) |
| `GET` | `/api/notes/:id` | Full note for restore |
| `GET` | `/api/health` | For the Settings status |

**Acceptance:** edit a note → it appears in Neon within ~1 min; record 10 min → the audio lands in the `uploads` bucket with a matching SHA-256; delete the app → reinstall → Restore → every note, drawing, recording, and transcript is back, and replay sync still works; airplane mode → nothing breaks, and the backup catches up when you're back online.

---

## 9. Interaction details

- **Palm rejection:** handled by `.pencilOnly`. Fingers never create ink.
- **Zoom:** pinch 0.75×–3×. The zoom level doesn't persist.
- **Lasso selection:** drag to move. Selection menu: Cut, Copy, Delete, Change Color (the first 6 favorites). Pasting places content at the viewport center.
- **Undo/redo:** the canvas `undoManager`, also covering element add, move, and delete.
- **Keyboard (with a hardware keyboard):** ⌘Z/⇧⌘Z, ⌘N new note, Space = play/pause when not editing text.
- **Rename:** titles are free text. An empty title reverts to `Note <date>`.
- **Delete** always confirms. Deleted notes go to Recently Deleted (a `deletedAt` timestamp, purged after 30 days), as in Notability. Until P1 lands, deletes are permanent.

---

## 10. Phase 2 / 3 hooks (what Phase 1 already provides)

1. **Transcripts with word timestamps exist for every recording** (7.6), in the same time frame as the ink (7.2).
2. **Everything is in Neon** (8.3), including `strokes_index` (per-stroke time + page + bounding box), so a server-side agent can work without the iPad being online.
3. **Every ink stroke, text box, and image has a wall-clock timestamp** (7.2). This is the join key that lets Phase 3 say "while Pat wrote *this*, the call was saying *that*".
4. **One drawing per note plus page geometry**, so Phase 3 can render each page (or each stroke cluster) to PNG for a vision model to read the handwriting.

**Phase 3 sketch (not for building now, just to confirm the data is sufficient):** the "Hand off to agent" button packages `{ page PNGs, strokes clustered into "moments" (spatially and temporally adjacent strokes) with their bounding boxes and timeline times, transcript window ±30s around each moment, note title/subject }` into one bundle. It POSTs the bundle to the same Inkwell API (8.3), which starts a Claude Code / Codex run. The agent reads the handwriting, lines up each moment with what was said, picks the repo, and turns items into tasks (for example, Code Queue issues) or code changes. Phase 1 only has to make sure all of that data exists, which items 1–4 cover.

---

## 11. Non-functional requirements
- **Ink latency:** matches PencilKit's native latency. No SwiftUI re-renders of the canvas while you draw. Keep the canvas out of any `@Observable` state that changes per stroke.
- **Scale:** 200 notes in the library; a 30-page note with 10k strokes and 2h of audio opens in < 1.5s on an M-series iPad.
- **Storage:** 64 kbps mono AAC ≈ 29 MB/hour. Postgres stays small (no large files). The Neon bucket holds the audio.
- **Live transcription** must not add ink latency or drop audio. Run the analyzer off the main thread. If it falls behind, drop volatile updates, never audio buffers.
- **Reliability:** no data loss on crash, force-quit, or low memory. Recording survives background, lock screen, and an app switch.
- **Accessibility:** toolbar buttons have labels. Dynamic Type in the library only; the canvas is fixed.

---

## 12. Build milestones (in order; each ends with a demo on an iPad or the Simulator)

| # | Milestone | Done when |
|---|---|---|
| M1 | Project + library | Xcode project `Inkwell` (iPad, iPadOS 26). SwiftData models. Sidebar with subjects CRUD + colors; note list with create/rename/delete/move; empty editor opens. |
| M2 | Ink editor | Paged canvas with paper styles, custom toolbar (Pen/Pencil/Highlighter/Eraser/Lasso), favorites + widths, undo/redo, autosave + thumbnails, page auto-append, page navigator, pencil-only drawing. |
| M3 | Recording | Record/Stop, recording bar with level meter, multiple recordings, background recording, crash recovery. **M3-5: timestamp survival test** (7.2) documented with results. |
| M3.5 | **Screens review with Pat** | Every screen exists and works at basic fidelity: library (sidebar + note list, empty and populated), subject create/edit, note editor (empty with paper footer, with ink), each tool's sub-bar, Paper sheet, note ⋯ menu, recording view (§6.12) in all its states, Settings. Capture Simulator screenshots of each into `review/<nn>-<screen>.png` (`xcrun simctl io booted screenshot`), list them in `review/README.md` with one line per screen, and **stop for Pat's feedback** before continuing. Expect design changes, especially to the recording view. |
| M4 | Synced playback | Playback bar, combined timeline with ticks, speed, **fade replay, tap-to-seek**; all §7.5 acceptance tests pass. |
| M4.5 | Live transcription | §7.6 end to end: model download, live volatile/final text in the recording view, JSON persistence, tap-line-to-seek, backfill "Transcribe", transcript search. §7.6 acceptance passes with a real call on the Mac speakers. |
| M5 | P1 set | Text boxes, images, PDF import/export, content manager + bookmarks, recording rename/delete, dividers. |
| M6 | Cloud backup | (Neon project already linked and deployed; see §8.3 current state.) Schema applied, `api` Function + `uploads` bucket deployed, presigned uploads, Settings → Backup, background audio upload, restore. §8.3 acceptance passes. |
| M7 | Polish | Apply Pat's M3.5 feedback, perf targets (§11), no "extra" UI. |

Test the real pencil and audio behavior on a physical iPad; the Simulator can't test Apple Pencil pressure or double-tap. Unit-test the timeline math (`timelineTime`, offsets, hit-testing) with XCTest.

---

## 13. Risks & open questions

1. **Call audio — resolved.** Pat's calls play from the Mac Studio speakers, and the iPad mic records the room, the same as with Notability today. The only risk is voice processing stripping the speaker audio (§7.3). Note: an iPad app can't capture another app's audio, so a call on the iPad itself, or with AirPods in, would record only Pat.
2. **`creationDate` stability** under lasso-move, paste, and partial erase (7.2). Validate this in M3.
3. **Replay render performance** on very long notes (7.4). Fallback: a custom renderer.
4. **iPadOS 26 minimum.** Pat is checking his iPad and may update. If the device can't run 26, live transcription (§7.6) isn't available. The fallback would be the older `SFSpeechRecognizer` with on-device mode, which is worse on long audio. Decide then.
5. **Backup is one-way** (8.3): iPad → cloud, plus restore. Real two-way sync across devices is not planned. Everything runs on Pat's Neon project, which is already linked and deployed (§8.3).
6. **Subject counts** show only on the selected subject (Notability behavior). Keep it or show them all? Default: match Notability.
7. **Straight-line snap and shape detection** (Notability Settings → Handwriting: draw, then hold to straighten or snap to a shape) are left out of Phase 1. They're good candidates for right after M7.
8. **Transcription accuracy** on speaker audio, no speaker labels, no custom vocabulary (7.6). Upgrade path: server-side re-transcription.

---

## Appendix A — Notability inventory observed (Mac app, 2026-09-24)

**Main toolbar (page 1):** Text · Boxed/Freeform select · Media · Pen · Pencil · Highlighter · Eraser · Mic *(becomes "Start Playback" ▶︎ once the note has audio)* · | · Navigate · › more
**Toolbar page 2 (›):** Navigate · Laser · Tape · Start Recording · Toolbar settings
**Pen sub-bar:** 3 color favorites (black, blue, red) + add · 3 width dots · stroke-style curve
**Highlighter sub-bar:** 3 favorites (yellow, magenta, green) + add · 3 widths · stroke-style
**Select sub-bar:** Freeform | Boxed
**Playback bar:** ⟲10 · ⟳10 · scrubber with a recording-boundary tick · elapsed/total (0:19 / 21:38) · ⋯
**Playback ⋯ popover:** Recordings (Edit) → "Recording 2 · 8m 48s · 1/22/25, 5:41 PM" · Playback Settings → Tuning (L/Both/R + 5-band EQ) · Playback speed (Normal) · Show transcripts on play (toggle) · Voice Boost slider
**Replay behavior:** unplayed ink faded, darkens in sync; pre-recording ink stays dark
**Content manager:** Pages | Transcripts · Search · All Pages filter · numbered thumbnails with bookmark ribbons · Select · expand
**Transcripts tab:** timestamped segments ("0:00 · Processing…"), subscription upsell for unlimited transcription
**Page navigator:** ^ 1 / 6 v, bottom-right
**Empty page footer:** Rule · Grid · Dot · | · Import · Templates
**Library sidebar:** Settings · Search · Notes · Gallery · Subjects (+) with color dots and count · promo banners
**Note list:** ⋯ options · + New · subject title (serif) · rows = thumbnail, title, date, mic glyph
**Menus — File:** Close, Close All, Duplicate, Move, Rename, Export As, New Note, New Window, New Note from Template, New Subject, New Divider, Import, Export, Print
**Edit:** Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All, Paste Image, Find, Insert Text Box, Insert Math, Insert Photo, Highlight, Deselect All …
**Format:** Font, Text, List Style, Indent, Outdent, Increase/Decrease Font Size
**Tools:** Select Tool 1–9, Select Last Tool, Start Recording, Start Playback
**View:** Show Toolbar, Customize Toolbar, Show Sidebar, Full Screen, Night Mode, Next/Previous Page, Go to Page, Hide Library, Show Page Navigator, Sort Notes

**Note ⋯ menu:** Quick share (PDF) · Share options · Template settings · View settings › (Seamless ✓ / Single Page / Night Mode) · Info ›
**＋ New:** a plain button; it creates "Note <date>" immediately (no menu)
**Templates sheet:** Cancel/Apply · Go to: From the Gallery / Basic Templates / Planners / Worksheets · Size: Letter (Optimized) · portrait/landscape · Basic: Plain, Rule, Grid, Dot (⋮ each) · 6 paper colors · Notepads row · tabs: Templates / My Templates
**Settings:** About, Subscription, Help · Auto-Backup, Manage Accounts, iCloud, Recently Deleted · Themes, Document, Typing, Handwriting, Audio, Locked Subjects · Text-to-Speech
  - Audio → Audio Transcription toggle ("Convert your audio recordings to text, making them readable and searchable")
  - Handwriting → Language, Math Conversion (paid), Straight lines (hold to straighten), Shapes Detection
  - Document → default note title "Note" + include date/time, default template (Plain, White, Letter, Portrait), default view Seamless / Single Page, media options

*Reference images:* none saved to disk (the shell has no Screen Recording permission, and the computer-use save didn't write files). Everything above was observed live. To give the build agent pixels, drop iPad screenshots into `research/screens/`, or let it look at the Notability Mac app directly.
