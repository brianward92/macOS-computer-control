# macctl — controlling this Mac

`macctl` drives macOS from a shell: it clicks, drags, types, reads the screen,
and checks whether any of it worked. It is on PATH. `macctl help` lists every
command and flag; `macctl help --json` is the same contract as data, generated
from the table the parser uses, so it cannot drift from the binary.

It is an instrument, not an agent. It does exactly what it is told, reports what
it observed, and refuses when it cannot tell. Deciding what to click — and what
not to — is your job. There is no safety layer: it will click Log Out, press
Send or quit an app if told to. Before any irreversible click, read the screen
and be sure what is under the pointer.

## The working loop

Every step is **observe, act, verify**. Most commands answer in well under a
second, so the loop should feel like a conversation with the screen, not blind
moves followed by a long wait.

1. **`macctl doctor` first.** Exit 0: everything is permitted. Exit 3: a
   permission is missing — stop and tell the person what to grant (the output
   says where). Nothing you send will land until they do.
2. **Hold the display awake:** `macctl awake --while-pid $$`. A display that
   sleeps mid-run comes back locked, and nothing here gets past a password.
3. **Name the app exactly.** `macctl apps` lists what is running (see
   [Naming an app](#naming-an-app)).
4. **Get it on screen:** `macctl launch App`, then
   `macctl wait-for App "expected text" --timeout 30`. For a browser,
   `macctl navigate App <url>` asks the browser to open a URL, which may create
   a new tab according to the browser's settings. It waits for stable app text;
   that is not proof the requested page has loaded. Use `macctl browser App`
   to check the observed document URL, then wait for a page-specific condition.
   After a click that triggers a load or transition, `macctl wait-idle App`
   returns the moment the content settles. Never `sleep N` and hope.
5. **Act by label wherever there is one:**
   `macctl click-text App "Open" --timeout 3` finds the label, checks it is
   unique, and clicks it. Use fractions (`macctl click App 0.5 0.6`) only for
   things with no text: a canvas, an icon, a game board. For standard controls
   in a native app, prefer accessibility (see [Two ways to act](#two-ways-to-act)).
6. **Send keys to a named app:** `macctl type --app App "hello"`,
   `macctl key cmd+s --app App`. Without `--app` they go to whatever is in
   front. With it, the app is brought forward first, and the command refuses
   (exit 4) rather than type into the wrong window.
7. **Verify the effect, not the delivery:** `macctl verify App "Saved"`, or
   `macctl wait-for App "…" --gone`. Verify against something the action
   *removes*: after "Done", check the sheet's text is gone, not that a button
   behind it is still there.
8. **Finish clean:** `macctl restore` (see [Finish clean](#finish-clean)).

```bash
macctl doctor
macctl awake --while-pid $$
macctl launch "Example App"
macctl wait-for "Example App" "Welcome" --timeout 60
macctl click-text "Example App" "New Document" --timeout 3
macctl type --app "Example App" "The quick brown fox"
macctl verify "Example App" "quick brown fox"     # did the text arrive?
macctl key cmd+s --app "Example App"
macctl wait-for "Example App" "Saved" --timeout 10
macctl restore                                    # put the person back where they were
```

## Three things to internalise

**A click that lands on nothing reports success.** Posting an event returns
nothing, and neither the OS nor the app says whether it landed. Event delivery
commands, including `click-text`, report `"verified": false`. `click-text`
satisfied means "found a unique label and delivered a click," not "the app
reacted." If it matters, follow up with `verify` or `wait-for`.

**Unknown is not failure.** Exit 2 means "could not observe" and always carries
a reason. Look again; never treat it as "did not happen".

**Never cache a window rectangle.** Coordinates are fractions of the window,
top-left origin. Geometry is read live inside every command and echoed back
with `readAt`, so nothing needs retaining between commands.
`click-text` also rechecks the window identity, bounds, and focus after OCR
and after moving the pointer. If they changed, it sends no click and reports
the reason; read the screen again before deciding what to do next.

## Reading a result

One JSON object per line on stdout; human text on stderr. The exit code is the
answer:

| Code | Meaning | What to do |
|---|---|---|
| 0 | satisfied | carry on |
| 1 | unsatisfied — acted, observed, it did not happen | read the screen, then decide |
| 2 | unknown — could not observe (reason given), or bad usage | look again; for usage, fix the command |
| 3 | refused — permission missing, Secure Event Input held, screen locked, session not on the console | stop; only a person can fix this |
| 4 | refused before doing anything — no such app, ambiguous name, no window, app would not come to the front | fix the request; retrying will not change it |

Fields worth reading: `outcome` (`satisfied`, `unsatisfied`, `unknown: why`,
`refused: why`), `verified`, `window.frontmost`, `window.windows` (more than one
means you are addressing the front one), `window.readAt`, `wokeScreen` (the
display was dark and was woken first), and on reads `capturePath` and `scale`.

## Naming an app

A bundle id, an exact name, or a substring that matches exactly **one** running
app. `Code` with Xcode and Visual Studio Code both running is refused (exit 4)
with both names listed — never resolved by guessing. Ordinary Dock apps are
tried first and menu-bar agents only if nothing ordinary matches, so system
agents do not make every short name ambiguous. Helper processes (renderers, GPU
processes) are never candidates.

The app's window is its **front** on-screen window; a sheet or dialog in front
of the main window *is* the window. Pixel and keyboard input bring the app forward first
and wait for the window server to agree. If it will not come — another app's
modal dialog, a full-screen Space — they refuse with exit 4 and name what is in
front.

## Two ways to act

**Pixels** (the default): OCR to find things, mouse and key events posted at
coordinates. The only option for an app with no accessibility tree — a game, a
web canvas.

**Accessibility**: acts on a named element, so there is no coordinate to miss.
Needs Accessibility permission.

- `macctl controls App --scope window` — controls in the selected accessible
  window, with role, value, identifier, URL, bounds and editability where exposed.
  Prefer this scope during normal UI work. The default `--scope app` preserves
  whole-app discovery, including menus and other windows.
- Filter discovery with `--role AXTextField`, `--match "Search"`, or
  `--identifier ID`. `--exact` disables substring fallback for label/value matching.
- `macctl activate App "<control>" --scope window` — press a button or checkbox,
  or open a popup. Reuse the same scope and selectors used for discovery. A label
  can be omitted when `--role` or `--identifier` uniquely selects the control.
- `macctl set-value App "text" --scope window --identifier ID` — set an editable
  field through its accessibility value, then read it back. This does not type
  into whichever field happens to have keyboard focus, and does not submit a form.
  `verified` describes the field value only, not a save or downstream response.
- `macctl choose App "<popup's current value>" "<new value>"` — set a popup.
  Reports `before`/`after`, so it acts and verifies in one call.

Labels and identifiers are app-provided and can repeat. Discovery reports
`truncated` and exits 2 if the tree was incomplete; actions refuse to infer
uniqueness from incomplete discovery. Multiple matches require a more precise
selector. Secure, disabled, or non-settable fields are refused before a value write.
Native control actions address AX elements directly and can work while the app is
in the background. Window scope uses the focused or main accessible window, or
the sole accessible window when neither is exposed, and prefers an attached sheet.

```bash
macctl controls Safari --scope window --role AXTextField
macctl controls Safari --scope window --role AXLink --match "Documentation"
macctl set-value "Example App" "sample query" --scope window --identifier search-field
macctl activate "Example App" "Search" --scope window --role AXButton --exact
```

Use `macctl browser Safari` for browser state instead of an ad hoc `osascript`
query. It reports the selected window, committed page URL, address-bar text and
observed tabs from native accessibility. Address-bar text may be an unsubmitted
edit; it is never substituted for the page URL. Missing attributes remain null
with a reason. Tab indices and identifiers are observations, not persistent tab
handles. Background-tab URLs may be unavailable. Read state again after a
navigation or tab change, and stop dependent actions when a command fails.

Pixels have one hard limit: **a modal sheet or popup runs its own event-tracking
loop and silently swallows posted mouse clicks.** In System Settings the button
that opens a sheet clicks fine, but the sheet's popups and its Done button
ignore every posted click and still report success. If a `click` or
`click-text` succeeds and nothing changes, this is why — switch to
accessibility. Dismiss-style buttons also respond to `key return --app X` or
`key escape --app X`.

```bash
macctl activate "System Settings" "Night Shift"           # opens the sheet
macctl wait-for "System Settings" "Schedule"              # sheet is up
macctl choose "System Settings" "Off" "Sunset to Sunrise" # a popup clicks could not move
macctl activate "System Settings" "Done"                  # a button clicks could not press
macctl wait-for "System Settings" "Schedule" --gone       # confirm it closed, by absence
```

Reading splits the same way. **`macctl text App`** reads content through the
accessibility tree — fast, verbatim, a whole scrolling page in one call — and
falls back to OCR only when there is no tree. Use `read`/`find` (OCR) only when
you need *where* something is, since they return click points.

Rule of thumb: labelled standard control (button, popup, checkbox, menu item)
→ accessibility. Game, canvas, drawing, a spot with no control → pixels.

## Finish clean

A one-shot request should leave nothing hanging: close the sheet you opened,
quit the app you launched only for the task, and hand focus back. If the person
walked away, they should come back none the wiser.

The tool keeps the bookend for you. The first command that moves focus
(`launch`, `focus`, `navigate`, any click or drag, `click-text`, `activate`,
`choose`, `dock menu`, or `key`/`type` with `--app`) records which app was in
front; later commands leave the record alone. `macctl restore` brings that app
back and clears the record, so it is the last line of every run that drove
anything:

```bash
macctl activate "System Settings" "Done"             # close what you opened
macctl wait-for "System Settings" "Schedule" --gone  # confirm it closed
macctl key cmd+q --app "System Settings"             # quit it if you launched it for this
macctl restore                                       # back to where they were
```

Individual commands deliberately do not restore focus — a multi-step flow needs
it to stay on the target. `macctl front` and `macctl doctor` show the record as
`origin` (null when none). A record is dropped once its app has quit or it is
over twelve hours old, so a crashed run cannot send the next one to a stale
window; `doctor` mentions a leftover.

Don't undo the change the request was *about* (the Night Shift setting stays
set). If the point was to land them in a new app, leave them there and end with
`macctl restore --forget`, which drops the record without moving focus.

## Timeouts, and why agents look frozen

The tool never waits longer than it was told. When an agent seems stuck, it is
almost always one of these:

- **One look treated as absence.** Reading an animated control misses about one
  look in eight. `verify` takes three looks before saying absent. `click-text`
  and `find` take one look unless given `--timeout`, and a single miss is exit
  2, not 1. Give `click-text` two to five seconds; it returns as soon as it
  finds the label.
- **Waiting on an app that is not running.** `click-text --timeout` rides out a
  missing or not-yet-frontmost window, but refuses at once if the app is not
  running or the name is ambiguous. `wait-for` is the one that waits for an app
  to start.
- **A modal dialog.** It blocks every later synthetic event and only a person
  can dismiss it — so never trigger one. If a command that worked starts
  reporting exit 4 "could not bring X to the front; Y is in front", Y is
  probably a dialog.
- **The watchdog.** Every command has an independent 45-second watchdog
  (`--timeout S` gets `S + 30`). A watchdog exit is code 2 and means the
  screen-capture stack wedged; try once more, then tell the person.
- **Retrying a refusal.** Exit 4 will not change by itself. Change the request.

## Things that will catch you out

- **Matching prefers the whole label.** `click-text App 7` clicks the button
  labelled 7, not the 7 inside a total: a box whose entire text is the needle
  beats a whole-word match, which beats a substring, and only ties at the best
  level are ambiguous. Use `--region` when the same label appears twice.
- **Rows merge.** `read` merges boxes sharing a row into one line — right for a
  label beside a count, wrong for a row of separate controls, whose merged
  centre lands on nothing. Use `read --boxes`. A `find`/`click-text` hit inside
  one box is narrowed to the matched words; a hit only through a merged line
  carries that line's whole rect.
- **Recognised text is not the text.** Vision substitutes look-alike letters
  from other alphabets, so a plain string compare can miss a visible label.
  `find` and `click-text` fold homoglyphs; your own comparisons should use
  `Text.fold`.
- **Outside the window needs `--screen`.** System dialogs, Screen Time shields
  and the Dock are in no app's window. `--screen` is the main display.
- **`--region` is clipped to the window;** one wholly outside it is an error.
  The reported rect is the area actually read.
- **Park the pointer before reading and clicking.** Hover previews cover what
  you meant to read and steal clicks. `read` does not move the cursor.
- **Some UIs distinguish clicks from drags.** Use the gesture the app expects,
  and verify the result.
- **`type` sends one real keystroke per character**, using the key the active
  layout maps it to, so apps that read keys (a calculator, a game, a terminal)
  see every character. Characters no key produces (emoji, other scripts) arrive
  as text.
- **Chords follow the active layout.** `cmd+z` is the key that produces `z` on
  the current layout. Named keys (`return`, `escape`, `f5`, `forwarddelete`) are
  layout-independent.
- **Secure Event Input** (a focused password field, Terminal's secure entry)
  discards keystrokes. `doctor` reports it; `key` and `type` refuse with exit 3.
- **A failed capture is exit 2, never an empty read.** Missing Screen Recording
  permission is exit 3.
- **Permissions need a terminal relaunch after granting.** The checks are
  process-cached with no live probe.
- **A dark screen is handled** — woken (or the screen saver dismissed) before
  reading, and reported as `wokeScreen`. If it cannot be woken, exit 3 rather
  than reading a black frame.
- **A locked screen is reported, not worked around.** Input refuses with exit
  3; reads still work, so you can watch a machine you cannot touch.
- **`dock menu` is the least predictable command.** It copes with an
  auto-hiding, magnifying Dock by revealing it and walking the pointer onto the
  icon, but takes a few seconds. Prefer `key cmd+q --app X` to quit an app.

## Commands

```
macctl doctor | apps | front | help [--json]
macctl awake [--while-pid N | --seconds N | --off | --status]
macctl launch <app> [--via-spotlight] [--timeout S]
macctl window|focus <app>
macctl restore [--forget]
macctl browser <app>
macctl navigate <app> <url>        macctl wait-idle <app>
macctl move|click|press|release <app> <fx> <fy>
macctl drag <app> <fx1> <fy1> <fx2> <fy2>
macctl scroll <app> <fx> <fy> <amount>
macctl key <chord> [--app APP]     macctl type [--app APP] <text>...
macctl text <app>                  macctl shot|read|find <app>|--screen ...
macctl click-text|verify|wait-for <app> <text> [--region] [--timeout S] [--gone]
macctl controls <app> [--scope window] [--role ROLE] [--match TEXT] [--identifier ID]
macctl activate <app> [<control>] [--scope window] [--role ROLE] [--identifier ID]
macctl set-value <app> <value> --scope window --identifier ID
macctl choose <app> <popup> <value>
macctl dock list                   macctl dock menu <app> <item>
```

`macctl help` has every flag with its default. Flags are `--name value` or
`--name=value`; anything after a bare `--` is positional; an unknown flag is a
usage error (exit 2). For `type`, `--app` must come first — everything after it
is text.

The clients in `clients/` (Python, TypeScript, MCP) are intentionally partial
wrappers. The CLI and `macctl help --json` are the complete contract.

## Building and testing

- `bash scripts/build.sh` — plain `swiftc`, no dependencies. Builds
  `MacControlKit` as a static module, then `macctl` against it — the same two
  modules as `Package.swift`. The script is the primary build because SwiftPM
  fails on a Command-Line-Tools-only machine whose `libPackageDescription` is
  version-skewed against the compiler.
- `bash scripts/install.sh` — build and symlink into `~/.local/bin`.
- `bash scripts/test.sh` — unit tests for the decision logic (app resolution,
  window selection, outcome rules, argument parsing, text folding, matching,
  cropping, keystroke mapping) plus a CLI usage smoke test. Nothing touches the
  screen or posts input.
- For a live check, Calculator is a safe target: launch it, drive it with
  `click-text` and `type --app Calculator`, verify the display, quit with
  `key cmd+q --app Calculator`.

`AGENTS.md` is a symlink to this file; edit `CLAUDE.md`.
