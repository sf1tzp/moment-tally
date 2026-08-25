# Driving Moment Tally via System Events / AX

Shared reference for the `verify` and `capture` skills. This is where the
hard-won AX knowledge lives — keep additions here, not in the individual
skills, so the two don't drift.

## Element map

- The status item is `menu bar item 1 of menu bar 2`; its label is "Timer" when
  idle, "● M:SS" while running.
- The popover is the untitled window: `window ""`. Its rows are unnamed buttons
  of `group 1` in layout order (idle: quick-start sets first, then Log,
  Calendar, History, Settings…, Quit; running: Stop first).
- The Moment Tally window is `window "Moment Tally"`; switch tabs via
  `click button "<Label>" of toolbar 1`. Tab content lives under
  `group 1 of group 1`; the week navigator is buttons 1-4 (prev, Today, next,
  refresh); log rows are unnamed buttons of `UI element 1 of scroll area 1`.
- Buttons expose no names/titles — identify by `position`/`size`.
- Deleting opens a `sheet 1` with `button "Cancel"` and `button 2` (= Delete).

## Hard-won caveats

- **Never verify text entry via AX**: `set value of text field` bypasses the
  SwiftUI binding (Save then persists the old value), and NSHostingView
  recycles NSTextFields so later AX reads return your own phantom text even in
  fresh view instances. Synthetic `keystroke` is also unreliable here. Verify
  note/tag *text* edits manually; clicks (expand, save, delete, navigate) are
  reliable.
- **Never drive AX with two Moment Tally instances running** (learned 2026-07-29
  testing Sparkle): the user's installed copy + a test build are two processes
  with the same name, and even `first process whose unix id is <pid>` sessions
  ended up enumerating the *other* app's popover. Both instances also share
  the real database and defaults — a `HOME=` env override does NOT isolate
  anything (`NSHomeDirectory()`, UserDefaults, and Application Support all
  resolve the real home). Ask the user to quit the installed app (or note
  you're doing it) before any popover/settings driving of a test build.
- The status-item click *toggles* the popover, and it stays open across
  osascript runs — guard with `if not (exists window "" of p)` before
  clicking again, or a fresh script closes what the last one opened.
- The popover window is not reliably `window ""` — on macbook-air
  (2026-08-03) it enumerated as `window "Untitled"`. Address it as
  `window 1` (the Moment Tally window is findable by its real name, so the
  popover is whatever's left) and check `name of every window` when lost.
- Collective element queries on the popover (`buttons of group 1 of
  window 1`) can fail wholesale with `-10000` even when the elements exist —
  iterate `UI elements of …` and filter on `role` instead.
- **Tab-order tracing works** (2026-08-03, found the #134 key-view-loop bug):
  focus a field, then loop `keystroke tab` + read `value of attribute
  "AXFocusedUIElement" of process` — reliable, unlike text entry. Caveats:
  `set focused of <field> to true` only takes if that window is key (with two
  windows the read silently returns the other window — `cliclick` into the
  field instead), and a field-style date picker reports its *label's* static
  text as focused while eating one Tab per date element.
- A fresh demo launch opens onboarding: click `button 1 of group 1 of
  window 1` repeatedly to advance, then close the walkthrough window it
  hands off to (`AXCloseButton`) before driving anything else.
- Views at `.opacity(0)` (e.g. hover-revealed controls) are absent from the
  AX tree entirely — not present-but-invisible. To reach them, hover with a
  real cursor move first (`cliclick m:x,y`, app frontmost), then re-query;
  their presence/absence also doubles as a check that the hover reveal
  works. Buttons identify nicely by their `help` attribute (read it per
  element inside a `try`; some elements throw).
- **Duplicate pop-up buttons alias the same control** (learned 2026-08-03 on
  the History tab): both "Group by" pickers enumerate as `AXPopUpButton`s,
  but `pop up button 2 of scroll area 1` reports picker 1's position/value
  and clicking it opens picker 1's menu — the right picker is unreachable
  through the tree. Workaround: read the right column's "Group by"
  `AXStaticText` position, `cliclick c:<x+95>,<y+6>` to open the real
  picker, then select by *menu type-select* (`keystroke "<item name>"`,
  `key code 36`). Typing the full item name wins over shorter siblings
  ("project" beats "proj") because a menu item can't prefix-match a buffer
  longer than itself.
- After `click` on a (working) pop up button, poll for `menu 1` *and* the
  target menu item — items populate late. A script that dies mid-menu
  leaves it open, and the next click toggles it shut: send Escape
  (`key code 53`) before retrying.
- SwiftUI segmented controls (`AXRadioGroup`) click fine via
  `radio button N`, but a disabled control silently no-ops — read the
  values back to confirm the switch took.
- **`button N` and `UI element N` index differently** (learned 2026-08-03
  driving the popover): `button 24` counts only buttons and fails with
  "Invalid index" past their count, while an element enumeration that showed
  a button as the 24th child needs `UI element 24`. When a click errors
  -1719 on an element you just enumerated, re-address it by element index.
  Coercing `position of e as string` concatenates x,y with no separator
  ("1137612" = 1137,612) — fetch coordinates separately if you need math.
- The popover's **Settings… row switches the main "Moment Tally" window to its
  Settings tab** — no separate settings window exists, and ⌘, does nothing.
  Onboarding's unnamed footer buttons are the last three of `group 1`
  (Back / Skip Tour / Next); pick "Skip Tour" as the ~85pt-wide one.
- **Color pickers drive fine end-to-end** (2026-08-03, card-color verify):
  click the `AXColorWell` swatch → panel appears as `window "Colors"` of the
  app process; a `cliclick` inside the wheel applies live to the SwiftUI
  binding (no OK step — unlike text fields, this path is trustworthy).
  Close it via `button 1 of window "Colors"` before driving on.
- **The popover's anchored color picker (#13) is invisible to AX windows**
  (2026-08-04): the child NSPopover never enumerates in `windows` of the
  process — the count stays 1 while it's plainly on screen. Screenshot to
  confirm it opened, then drive it by `cliclick` screen coords (the wheel
  and preset clicks apply live to the binding, same as the Colors panel).
  The swatch buttons identify by `help` ("Choose color").
- **NSColorSampler dismisses the MenuBarExtra popover** the moment its
  magnifier overlay appears (both the menu popover and the child picker
  close). The sample still lands — the callback fires and writes through
  the model, and the edit session survives — so verify by reopening the
  popover afterwards, not by watching for it to stay up.
- **cliclick drives SwiftUI drags reliably** (2026-08-04, verifying #155 row
  reorder): `cliclick -e 120 dd:x,y w:250 m:… m:… w:400 du:x2,y2` — a few
  intermediate `m:` moves plus the waits are what make the drag register;
  a bare `dd`/`du` pair does not. Works for `onDrag`/`onDrop` (and
  `.draggable`) in regular windows and for plain `DragGesture`s anywhere.
  The grip images themselves don't enumerate via AX — compute their screen
  points from a screenshot (or from a sibling `AXColorWell`'s position) and
  drag by coordinates, app frontmost. Mid-drag screenshots race the
  reshuffle animation — trust the end state, not the mid-drag frame.
- **Approach the press point with real `m:` moves before `dd:` (or `c:`)**
  (2026-08-05, #178 launcher cards): `dd:` teleports the cursor and presses
  in one event, and a `DragGesture` under a Button then never activates —
  the same drag recipe works iff the cursor was already moved onto the
  target first (`cliclick m:x,y-Δ w:… m:x,y w:…`, then drag). Hover-revealed
  UI has the same need for other reasons (see `.opacity(0)` above). Short
  one-slot hops are where the skipped approach bites hardest.
- **`DragGesture` needs `dm:` between `dd:`/`du:`, not `m:`** (2026-08-05):
  `m:` posts plain mouse-moved events, which an active `DragGesture` never
  sees — every `m:`-based "drag" collapses into one onChanged at release,
  so live reshuffles don't animate and only the final position registers.
  `cliclick -e 120 dd:… w:… dm:… dm:… w:… du:…` drives the gesture
  incrementally. NSDraggingSession (`onDrag`/`.draggable`) tracks the HID
  cursor and tolerates `m:`, which is why the older recipe above got away
  with it.
- **`onDrag`/`onDrop` strands sessions when the drop concludes over the
  drag's own source view** (2026-08-05, #178): in the Launcher grid the live
  reshuffle parks the dragged card under the cursor, `performDrop` flakily
  never fires, and the stranded session eats the next click — concluding on
  it as a drop (a surprise `dropEntered` move) instead of a click. Escape
  clears the stuck session. The row editors dodge it by topology (drag
  source = grip, drop target = row); the Launcher dodges it by using a 2D
  `DragGesture` instead (see `CardReorderGesture` in LauncherView.swift).
- **The MenuBarExtra popover never delivers internal drag-and-drop**
  (2026-08-04): an `onDrag` from a popover row starts a session (the
  preview appears, then sticks) but no `onDrop`/`DropDelegate` in the same
  popover ever fires, and the stuck session eats the next click — send
  Escape to clear it. That's why the popover's row reorder is a plain
  `DragGesture` (`GestureReorderGrip`), not the system drag the window
  editors use.
- **The Label Review tree drives well** (2026-08-04, #69 verify): it's
  `outline 1 of scroll area 1 of group 1 of group 1` with `AXRow` children
  whose `position`s are global points (rows are 26pt, instances 24pt — row
  centre ≈ top + 13). The disclosure chevrons don't enumerate; click them by
  coordinates at the row's left edge (key rows ≈ 16pt in from the window's
  left content edge, value rows ≈ 30pt). Counting rows after each click is a
  cheap expand/collapse assertion. Its `.draggable` value rows accept the
  same `cliclick -e 120 dd:… m:… du:…` recipe as row reorder; drop onto a
  key row's centre.
- **Sheets may not enumerate at all** (2026-08-04, Label Review's
  RenameSheet): no `sheet 1`, and `entire contents` doesn't surface its
  buttons either. But the sheet's text field takes focus on open and real
  keystrokes are trustworthy there (unlike the popover editors): `cmd+A` +
  `keystroke "…"` sticks, and Return fires the `.defaultAction` button.
  Confirm what got typed from a screenshot before committing.
- The popover's menu rows (Label Sets/Log/Calendar/…) are unnamed
  `AXButton`s with no readable static-text children; identify them by
  y-order — they sit below the quick-start sets, separated by the "N more…"
  row — and click via AX element reference, not coordinates.

- **Onboarding-walkthrough drive that worked** (2026-08-13, rehearsed +
  recorded, beats verified frame-by-frame): welcome→walkthrough is
  `click UI element 2 of group 1 of window 1` (`button 2` errors — index by
  element). Footer Back/Skip Tour/Next are the last three buttons; the
  window stays fixed (700×592) so Next is one static point. Page beats:
  p1 pencil → "+ Add Mark" → type into the new row via `cliclick t:`
  (**editor fields shift ~14pt when the row appears — re-read the
  AXTextField positions after Add Mark, and expect the whole hero to
  re-centre when the editor opens**); p2 Group-by popup + menu type-select;
  p4 a smell card click corrupts, the same point clicks again to heal;
  p5 the mock-tally quick chips live in the bottom row of the card's one
  AXButton (~78% of its 89pt height — clicking higher hits the card body,
  which no-ops visibly), and same-key chips swap rather than stack;
  p6 persona cards open on a hover-approach + body-centre click (the ⊕
  ignores synthetic clicks), name field then sits at the editor top and
  types reliably. All-cliclick driver, ~1.1× nominal sleeps for drift,
  total ≈50s; a fresh `--demo` relaunch fully resets the walkthrough for
  retakes.

## Screenshots & recordings

- Stills: best results from `screencapture -x -l <CGWindowID>` — captures
  just that window with its native shadow on a transparent background, no crop
  math. Get the ID with a tiny compiled Swift helper calling
  `CGWindowListCopyWindowInfo` (filter on owner name; there's no pyobjc to do
  it from Python). The popover (`window ""`) and the Moment Tally window each
  have their own ID. Falling back to full-screen + crop: `sips -c <h> <w>
  --cropOffset <y> <x>` (pixels = points × 2), but beware `--cropOffset 0 0`
  is treated as unset and crops from the *center* — use `1 1` for top-left.
- Recordings: `screencapture -v -R "x,y,w,h" out.mov` (region in points; get
  the window's `position`/`size` from AX first, and add margin if you want
  the shadow). `-V <seconds>` caps the duration so the run needs no manual
  stop; drive the scene from a second shell while it records.
- **SwiftUI drags need the app frontmost** (2026-08-04, Label Review value
  drag): if another app is active, the initial `dd:` mousedown only
  activates the window and the drag session never forms — same recipe
  succeeds after `set frontmost of process "MomentTally" to true`. Set it
  immediately before every scripted drag.
- **`cliclick t:<text>` types reliably where AppleScript `keystroke` fails**
  (2026-08-04, popover editor): the CGEvent typing path lands in the
  focused in-popover text field and survives Done/commit; `keystroke` into
  the same field drops silently. Prefer `cliclick t:` for any popover text.
- **Backgrounded `(screencapture -v … &)` starts unreliably** inside
  compound commands — it sometimes never creates the file, and a region
  that exceeds the display (height past the bottom edge) fails silently
  too. Run `screencapture -v` in the *foreground* and background a driver
  script (`(driver.sh &) && screencapture …`) for choreographed recordings;
  also remember the main display may be an external monitor (read its
  point size before computing regions).
- **Solid-wallpaper recordings**: back up `~/Library/Application
  Support/com.apple.wallpaper/Store/Index.plist`, `tell every desktop to
  set picture to <png>` (a generated 64×64 solid `#16161a` works), record,
  then restore the plist and `killall WallpaperAgent`. Hide the driving
  terminal with `set visible of process "Alacritty" to false` — the
  session's commands keep running while it's hidden.
- **MenuBarExtra popover toggle discipline for recordings**: every AX
  enumeration session that opened the popover must close it again before
  the take, and windows left over from onboarding (walkthrough → main
  window) overlap popover-region captures — close them all and verify
  with a CGWindowList helper that *zero* app windows remain on screen.
- **Bulk attribute reads beat per-element iteration** (2026-08-07, popover
  driving): `repeat with e in (UI elements of …)` re-resolves each element
  by index and -10000s flakily even right after a successful `count`.
  `set rs to role of UI elements of …` / `position of UI elements of …` /
  `help of UI elements of …` fetch whole columns in one AppleEvent and are
  reliable (absent attributes come back as `missing value`, no try needed).
  Read everything you'll need *early* — trees go stale after clicks cause
  reflows — and cache positions that survive the reflow (e.g. the top
  timer's Stop button keeps its spot when a second timer appears).
- **Hover-reveal rows: approach horizontally, target from AX at runtime**
  (2026-08-07, popover quick-start rows): a cursor path that crosses upper
  rows hover-expands them, shifting every later y — pre-baked coordinates
  from a rehearsal in a different hover state click the wrong row. Enter
  the row from *outside* the popover at its own y, and resolve chip
  positions (`help` bulk read) only after the expansion settles.
- **`.draggable`→`dropDestination` drops need a real event stream**
  (2026-08-07, Label Review value→key drag): the cliclick
  `dd:… m:… du:` recipe forms the drag session (preview + green badge)
  but `performDrop` fires maybe 1 time in 5 — synthesized batch moves
  starve `dropUpdated`. A tiny swiftc helper posting mouseDown, ~60Hz
  interpolated `leftMouseDragged` events (ease-in-out), ~0.5s of settle
  events over the target, then mouseUp landed the drop first try, every
  try (`smoothdrag x1 y1 x2 y2 [ms]` — source vendored beside this file as
  [smoothdrag.swift](smoothdrag.swift); `swiftc -O` it on demand). Frontmost still
  required, and Escape before retries still applies.
- **Focused vs unfocused window-ID stills differ in canvas size**
  (2026-08-07): `screencapture -x -l` pads the window with its shadow —
  56pt on every side for a *key* window (the 780×648 Moment Tally window →
  1784×1520 px), noticeably less when unfocused. Screenshot-to-screen
  coordinate math must use the focused margins (global = window origin +
  canvas_pt − 56), and mixing focused/unfocused stills in one batch
  changes rendition dimensions.
- **`screencapture -v -V <s>` recordings end 1–4s before the cap** and the
  written file's tail often can't be frame-extracted (`ffmpeg -ss` near
  the end yields nothing even though `duration` includes it). Pad the cap
  a few seconds past the choreography's last beat, and verify beats with
  frames a couple of seconds *before* the nominal end.
- **Check the display before any capture batch** (2026-08-13, aborted
  refresh): if Steven is connected via Screen Sharing in High Performance
  mode, the *only* display is a "Screen Sharing Virtual Display" — check
  `system_profiler SPDisplaysDataType` for it and for "UI Looks like". It
  ran 1x/30Hz, so window-ID stills AND recordings came out at HALF the
  shipped 1784px density — a whole batch of unshippable assets. The menu
  bar's mic pill + screen pill + ● timer belong to that session (clicking
  the screen pill offers "Disconnect <ip>" — don't); they are NOT a stuck
  screencapture. Capture batches need a real 2x display: lid open or a
  HiDPI-mode monitor.
- **`screencapture -v` can wedge for the rest of the session** (2026-08-13,
  on the virtual display): after a few successful takes every new one hung
  forever in `mach_msg` (no file, `-V` cap ignored, SIGINT exits without
  finalizing) while short driverless probes still worked; `killall replayd`
  and a ControlCenter restart changed nothing. `ffmpeg -f avfoundation
  -i "Capture screen 0:none"` kept recording fine (full display; crop the
  window region in post). Successful takes also repeatedly ended near the
  driver's last event rather than the `-V` cap — always `ffprobe` the
  duration and re-extract the final beats before accepting a take.
- `screencapture -v` refuses to overwrite: an existing target file fails
  the take at the very end with "Failed to save to final location" (the
  choreography still runs and mutates state). `rm` the target first.
- **Segmented controls by coordinates need the group's y-centre**: the
  History "Count marks" AXRadioGroup is 24pt tall; a click 2pt *above* its
  reported y silently misses (the pickers then get driven in the wrong
  mode). Compute `y + 12` from the AXRadioGroup position, or click via AX.
- The History Group-by aliasing above is **side-by-side-mode only**: in
  combined ("in Groups") mode both pop-ups enumerate with correct positions
  and values. And in side-by-side mode, an AX `click pop up button 1` opens
  the *left* picker reliably — good enough for restoring its value.
