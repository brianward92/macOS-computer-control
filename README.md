# macOS-computer-control

`macctl` — drive a Mac from a shell, and know whether it worked.

A macOS-only command-line tool that AI agents (and scripts, and people) use to
operate a computer. It clicks, drags, types, captures and reads the screen (OCR
and the accessibility tree), and drives native controls by name. Every result
says whether the effect was observed, and it separates "it did not happen" from
"I could not tell".

```bash
macctl launch Calculator
macctl key cmd+1 --app Calculator            # Basic mode, so the answer is in base 10
macctl key escape --app Calculator           # clear, and dismiss any tip popover
macctl type --app Calculator "12*34="
macctl verify Calculator 408                 # exit 0: it is on screen
macctl key cmd+q --app Calculator
macctl restore                               # hand focus back to where it was
```

## Your data stays on your Mac

`macctl` reads your screen, so this matters, and it is checkable:

- **It has no network code.** No telemetry, no analytics, no update checks, no
  uploads. It does not import a networking framework. The one command that
  touches a URL, `navigate`, hands the address you give it to the browser you
  name, exactly as `open -a Safari <url>` would.
- **Screen reading happens on your machine**, with Apple's own frameworks and
  tools: ScreenCaptureKit or `screencapture` to capture, Vision to recognise
  text.
- **Captures are not kept.** The image behind `read`, `find`, `verify` and the
  rest is held in memory; when it goes through `screencapture` instead, it is
  written to your private temporary folder and deleted as soon as it is read.
  The only screenshot saved is one you ask for with `shot`, written to `--out`
  or to your per-user temporary folder (`$TMPDIR`), which only you can read.
- **The only state it keeps** is at most two small files in `~/.cache/macctl`:
  the pid of its keep-awake helper, and the name and pid of the app to return
  focus to.

You build it from this source yourself, so you do not have to take this on
trust. The code is about 5,000 lines of Swift, and this finds any use of a
networking API:

```bash
grep -rnE 'URLSession|URLRequest|import Network|NWConnection|socket\(' Sources
```

**One thing to be clear about:** `macctl` hands what it reads — screen text,
screenshots, window names — to whatever runs it. If that is an AI agent, the
agent decides what happens next, and a cloud-hosted model will send it to its
provider as part of the conversation. Give an agent this tool only on a screen
you are content for that agent to see.

## Setup

**Requirements:** macOS 14 (Sonoma) or later, and the Swift 6 compiler — the
Xcode Command Line Tools are enough; full Xcode is not needed.

1. Install the compiler, if `swiftc --version` does not already work:

   ```bash
   xcode-select --install
   ```

2. Build and install:

   ```bash
   git clone https://github.com/brianward92/macOS-computer-control.git
   cd macOS-computer-control
   bash scripts/install.sh
   ```

   This builds `bin/macctl` and links it into `~/.local/bin`. If it warns that
   `~/.local/bin` is not on your PATH, add it to your shell profile:

   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   ```

   Set `BIN_DIR` to install somewhere else: `BIN_DIR=/usr/local/bin bash scripts/install.sh`.

3. Grant permissions. Open System Settings › Privacy & Security and enable your
   terminal app (Terminal, iTerm, …) — whichever app will run `macctl` — under:

   | Permission | Needed for |
   |---|---|
   | Screen Recording | reading the screen: `shot`, `read`, `find`, `verify`, `wait-for`, `click-text`, `dock menu`, and `text` when it falls back to OCR |
   | Accessibility | posting input (`click`, `drag`, `key`, `type`, …) and acting by name (`text`, `controls`, `activate`, `choose`, `dock`) |
   | Input Monitoring | posting input, on some macOS versions |

   Then **quit and relaunch the terminal**: macOS only applies the grant to
   newly started processes.

4. Check:

   ```bash
   macctl doctor     # exit 0 means everything is permitted
   ```

   Anything still missing is listed with where to grant it. Until it is, the
   commands that need it refuse with exit 3 rather than acting blind.

To uninstall, delete the link and the state folder, then remove the terminal
from those Privacy & Security lists:

```bash
rm ~/.local/bin/macctl && rm -rf ~/.cache/macctl
```

## Using it from an agent

Any agent that can run shell commands can use `macctl` directly.
[CLAUDE.md](CLAUDE.md) (also available as `AGENTS.md`) is the operating guide —
the working loop, the exit codes, and the pitfalls — and is written to be
handed to an agent as-is. Put it, or a pointer to it, in the instructions of
the project the agent works in. `macctl help --json` gives an agent the full
command contract as data.

For harnesses that speak MCP, `clients/mcp/server.js` exposes the common
commands as tools. It needs Node and nothing else. With Claude Code:

```bash
claude mcp add macctl -- node /path/to/macOS-computer-control/clients/mcp/server.js
```

Other harnesses take the same thing as a stdio server: command `node`, argument
the path to `server.js`. `clients/python` and `clients/typescript` hold small
wrappers for calling the CLI from code.

The Python and TypeScript `read`, `text`, `controls`, and `front` helpers
raise `ObservationUnknown` when the CLI cannot observe (exit 2), with the full
result available as `.result`. Successful empty observations keep their usual
empty return values. Action helpers and `run` preserve exit 2 in their result;
permission and target refusals remain `Refused` exceptions where checked.

## Safety

There is none, by design. `macctl` will click Log Out, press Send or quit an
app if told to. Deciding what not to do is the caller's job, so watch an agent
the first few times it runs, and keep it off screens it has no business with.

## Design

- **Exit codes are the API.** 0 satisfied, 1 unsatisfied, 2 could not observe
  (or bad usage), 3 refused on a precondition, 4 refused before doing anything.
  Stdout is one JSON object per line; stderr is for people.
- **Delivery is not verification.** A posted event that lands on nothing still
  "succeeds", so input commands always report `verified: false`, and `verify`
  and `wait-for` check the effect.
- **No cached geometry.** Coordinates are fractions of the app's current
  window, read live inside every command and echoed back.
- **Refuse rather than guess.** An ambiguous app name, a window that will not
  come to the front, or a locked screen is refused, never worked around.

## Layout

- `Sources/MacControlKit` — the library: geometry, input, capture, text
  recognition, accessibility, verification, the Dock, and system state.
- `Sources/macctl` — the CLI. Its command table generates the usage text, the
  flag parser and `help --json`.
- `Tests/MacControlKitTests` — plain-swiftc tests with no XCTest, so they run
  with only Command Line Tools installed: `bash scripts/test.sh`.
- `clients/` — intentionally partial wrappers for Python, TypeScript and MCP.
  The CLI is the contract; these only save subprocess boilerplate.

`bash scripts/build.sh` is the primary build. `Package.swift` describes the
same modules for SwiftPM, which needs a working Xcode toolchain.

`bash scripts/test.sh` runs the Swift and CLI checks without posting input.
`bash scripts/test-clients.sh` tests the Python and TypeScript wrappers against
a fake CLI; it requires Python 3.10+ and Node 22.6+ with TypeScript stripping.

## License

[MIT](LICENSE).
