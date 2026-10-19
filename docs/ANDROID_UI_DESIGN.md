# S1Print Android UI design

Native Android utility UI (platform widgets only, no new runtime dependencies, API 26+, target 36).
The Rust/JNI engine, `PrinterEngine`, `Documents`, `DirectPrintService` and `S1PrintService`
are unchanged; the UI only calls their existing public API.

## Screens

**Main (`MainActivity`)** — one scrollable column plus a sticky bottom bar:

1. Header: the real app logo (`@drawable/app_icon`, 48 dp, decorative because the title names the app),
   "S1Print" title, subtitle, and an About button (48 dp target, content description "About S1Print").
2. Status banner (polite live region): info while a job is pending, success, error, neutral.
3. Printer card: permission / Bluetooth off / unavailable / no paired / choose / saved-printer-missing /
   selected. "Check status" shows the printer's own reply with a timestamp; nothing is polled or invented.
4. Document card: empty, preparing, ready (name, type, pages), failed (message, retry, choose another).
5. Preview card: the exact 1-bit raster from the engine in a tiled `PreviewView`.
6. Print options (collapsed summary): density segmented control, fit to width, label paper.
7. Tools: test page, Bluetooth settings, system printing, About.
8. Bottom bar: reason/ready helper text, Print button (becomes "Printing to …" + Cancel while pending).

**About (`AboutActivity`, non-exported)** — parity with the macOS About window: logo, name,
installed `versionName` and `versionCode`, description, developer (Marvin Quevedo, GitHub profile),
Source Code, Report an Issue, fichero-printer / 0xMH credit, the MIT license read offline from
`res/raw/license_mit.txt` (keep it identical to the repository `LICENSE`), and the same notices.
Links use `ACTION_VIEW`; if no app can open one, an inline error shows the URL. No network permission.

## Tokens

Light theme only. Colors in `values/colors.xml` (background `#F4F5F7`, surface `#FFFFFF`, accent
`#0B63C5`, success/error containers). Text sizes in `sp` (title 28, card title 17, body 15, caption 13),
spacing on a 4 dp grid with 16 dp screen margins, 16 dp card radius, 12 dp control radius, 48 dp minimum
touch targets, content capped at 560 dp on wide screens.

## State rules

- `PrintTracker` (in-process) marks a job as pending only after `startForegroundService` succeeds, and
  clears only when `DirectPrintService` reports a result in the `lastResult` preference.
  `lastResult` is removed before queueing so two identical results still trigger the listener, and it is
  reconciled in `onStart` so a result delivered while the Activity was gone is not lost.
- Cancel sends the service's existing `cancel` action. If no result follows, only the explanation changes;
  Print stays locked until the real outcome arrives, so a possibly active job is never duplicated.
- Option changes invalidate any running preparation immediately (generation counter + per-run
  `CancelSignal`) and re-prepare from the stored `Source` after a 250 ms debounce, so stale results
  never apply old options. Large job JSON is never put in a Bundle; only the source URI is saved.
- Refreshing the printer list never clears the saved address; only an explicit choice (or first-time
  auto-select of a `PPS1*`/`S1_*` device) writes it. A saved but unpaired printer shows a dedicated state.
- Callbacks check `destroyed`; preview bitmaps are tiled (≤1024 rows) so long output never exceeds GPU
  texture limits, and are recycled after a short delay once replaced or released.

## Compatibility

- Edge-to-edge: `setDecorFitsSystemWindows(false)` on API 30+; before that only the status bar is drawn
  behind. API 26 uses an opaque dark navigation bar; `values-v27` switches to a light bar
  (`windowLightNavigationBar`); `values-v28` adds short-edge cutouts; `values-v29` disables contrast
  enforcement and force-dark.
- Font scaling / small width: no fixed heights; `ActionRow` and `SegmentGroup` stack vertically when
  their children do not fit, so text is never truncated horizontally. The page always scrolls.
- Accessibility: radio semantics for density, switch labels, live regions for banner/status/helper,
  headings (API 28+), decorative logo hidden from TalkBack.

## Validation

Instrumentation tests (`UiFlowTest.kt`) cover empty state, test-page and image import, error recovery,
option persistence and re-preparation, small saved state, About (version, author, credits, offline
license, Back) and the pure logic. None of them print or query a printer. Manual checks: API 26/27/34/36
emulators, font scale 2.0, 320 dp width, landscape, TalkBack, and a test-page print on a real S1.
